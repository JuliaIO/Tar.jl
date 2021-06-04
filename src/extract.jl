import SHA

function iterate_headers(
    callback::Function,
    tar::IO;
    raw::Bool = false,
    strict::Bool = !raw,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    eof(tar) && return
    hdr = read_standard_header(tar, buf=buf)
    hdr === nothing && return
    if !raw
        globals = Dict{String,String}()
    end
    if hdr.type == :g && hdr.path == SKELETON_MAGIC
        skip_data(tar, hdr.size)
        skeleton = true
    else
        if !raw
            hdr = read_header(tar, hdr, globals=globals, buf=buf)
        end
        skeleton = false
        @goto loop
    end
    while !eof(tar)
        hdr = if raw
            read_standard_header(tar, buf=buf)
        else
            read_header(tar, globals=globals, buf=buf)
        end
    @label loop
        hdr === nothing && break
        strict && check_header(hdr)
        callback(hdr)
        if !skeleton || hdr.type in (:g, :x) ||
            hdr.path == "././@LongLink" && hdr.type in (:L, :K)
            skip_data(tar, hdr.size)
        end
    end
end

function extract_tarball(
    predicate::Function,
    tar::IO,
    root::String;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    skeleton::IO = devnull,
    copy_symlinks::Bool = false,
)
    paths = read_tarball(predicate, tar; buf=buf, skeleton=skeleton) do hdr, parts
        # get the file system version of the path
        sys_path = reduce(joinpath, init=root, parts)
        # ensure dirname(sys_path) is a directory
        dir = dirname(sys_path)
        st = stat(dir)
        if !isdir(st)
            ispath(st) && rm(dir, force=true, recursive=true)
            mkpath(dir)
        else
            st = lstat(sys_path)
            hdr.type == :directory && isdir(st) && return # from callback
            ispath(st) && rm(sys_path, force=true, recursive=true)
        end
        # create the path
        if hdr.type == :directory
            mkdir(sys_path)
        elseif hdr.type == :symlink
            copy_symlinks || symlink(hdr.link, sys_path)
        elseif hdr.type == :file
            read_data(tar, sys_path, size=hdr.size, buf=buf)
            mode = hdr.mode & filemode(sys_path)
            if 0o100 & hdr.mode == 0
                # turn off all execute bits
                mode &= 0o666
            else
                # copy read bits to execute bits with
                # at least the user execute bit on
                mode |= 0o100 | (mode & 0o444) >> 2
            end
            chmod(sys_path, mode)
        else # should already be caught by check_header
            error("unsupported tarball entry type: $(hdr.type)")
        end
    end
    copy_symlinks || return

    # resolve the internal targets of symlinks
    for (path, what) in paths
        what isa AbstractString || continue
        target = link_target(paths, path, what)
        paths[path] = something(target, :symlink)
    end

    # follow chains of symlinks
    follow(seen::Vector, what::Symbol) =
        what == :symlink ? what : seen[end]
    follow(seen::Vector, what::String) =
        what in seen ? :symlink : follow(push!(seen, what), paths[what])
    for (path, what) in paths
        what isa AbstractString || continue
        paths[path] = follow([path], what)
    end

    # copies that need to be made
    copies = Pair{String,String}[]
    for (path, what) in paths
        what isa AbstractString || continue
        push!(copies, path => what)
    end
    sort!(copies, by=last)

    while !isempty(copies)
        i = 1
        while i ≤ length(copies)
            path, what = copies[i]
            # check if source is complete yet
            if any(startswith(p, "$what/") for (p, w) in copies)
                # `what` is an incomplete directory
                # need to wait for source to be complete
                i += 1
            else
                # source complete, can copy now
                deleteat!(copies, i)
                src = reduce(joinpath, init=root, split(what, '/'))
                dst = reduce(joinpath, init=root, split(path, '/'))
                cp(src, dst)
                if Sys.iswindows()
                    # our `cp` doesn't copy ACL properties, so manually set them via `chmod`
                    function copy_mode(src::String, dst::String)
                        chmod(dst, filemode(src))
                        isdir(dst) || return
                        for name in readdir(dst)
                            sub_src = joinpath(src, name)
                            sub_dst = joinpath(dst, name)
                            copy_mode(sub_src, sub_dst)
                        end
                    end
                    copy_mode(src, dst)
                end
            end
        end
    end
end

# resolve symlink target or nothing if not valid
function link_target(
    paths::Dict{String,Union{String,Symbol}},
    path::AbstractString,
    link::AbstractString,
)
    first(link) == '/' && return
    path_parts = split(path, r"/+")
    link_parts = split(link, r"/+")
    pop!(path_parts)
    part = nothing # remember the last part
    while !isempty(link_parts)
        part = popfirst!(link_parts)
        part in ("", ".") && continue
        if part == ".."
            isempty(path_parts) && return
            pop!(path_parts)
        else
            push!(path_parts, part)
            prefix = join(path_parts, '/')
            prefix in keys(paths) || return
            isempty(link_parts) && break
            what = paths[prefix]
            if what isa AbstractString
                prefix = link_target(paths, prefix, what)
                path_parts = split(prefix, '/')
            end
        end
    end
    isempty(path_parts) && return
    target = join(path_parts, '/')
    # if link ends in `/` or `.` target must be a directory
    part in ("", ".") && paths[target] != :directory && return
    # can't copy a circular link to a prefix of itself
    (path == target || startswith(path, "$target/")) && return
    return target
end

function git_tree_hash(
    predicate::Function,
    tar::IO,
    HashType::DataType,
    skip_empty::Bool;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    # build tree with leaves for files and symlinks
    tree = Dict{String,Any}()
    read_tarball(predicate, tar; buf=buf) do hdr, parts
        isempty(parts) && return
        name = pop!(parts)
        node = tree
        for part in parts
            node′ = get(node, part, nothing)
            if !(node′ isa Dict)
                node′ = node[part] = Dict{String,Any}()
            end
            node = node′
        end
        if hdr.type == :directory
            if !(get(node, name, nothing) isa Dict)
                node[name] = Dict{String,Any}()
            end
            return
        end
        if hdr.type == :symlink
            mode = "120000"
            hash = git_object_hash("blob", HashType) do io
                write(io, hdr.link)
            end
        elseif hdr.type == :file
            mode = iszero(hdr.mode & 0o100) ? "100644" : "100755"
            hash = git_file_hash(tar, hdr.size, HashType, buf=buf)
        else
            error("unsupported type for git tree hashing: $(hdr.type)")
        end
        node[name] = (mode, hash)
    end

    # prune directories that don't contain any files
    if skip_empty
        prune_empty!(node::Tuple) = true
        function prune_empty!(node::Dict)
            filter!(node) do (name, child)
                prune_empty!(child)
            end
            return !isempty(node)
        end
        prune_empty!(tree)
    end

    # reduce the tree to a single hash value
    hash_tree(node::Tuple) = node
    function hash_tree(node::Dict)
        by((name, child)) = child isa Dict ? "$name/" : name
        hash = git_object_hash("tree", HashType) do io
            for (name, child) in sort!(collect(node), by=by)
                mode, hash = hash_tree(child)
                print(io, mode, ' ', name, '\0')
                write(io, hex2bytes(hash))
            end
        end
        return "40000", hash
    end

    return hash_tree(tree)[end]
end

function git_object_hash(
    emit::Function,
    kind::AbstractString,
    HashType::DataType,
)
    ctx = HashType()
    body = codeunits(sprint(emit))
    SHA.update!(ctx, codeunits("$kind $(length(body))\0"))
    SHA.update!(ctx, body)
    return bytes2hex(SHA.digest!(ctx))
end

function git_file_hash(
    tar::IO,
    size::Integer,
    HashType::DataType;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    ctx = HashType()
    SHA.update!(ctx, codeunits("blob $size\0"))
    # TODO: this largely duplicates the logic of read_data
    # read_data could be used directly if SHA offered an interface
    # where you write data to an IO object and it maintains a hash
    padded_size = round_up(size)
    while padded_size > 0
        max_read_len = Int(min(padded_size, length(buf)))
        read_len = readbytes!(tar, buf, max_read_len)
        read_len < max_read_len && eof(tar) && throw(EOFError())
        nonpadded_view = view(buf, 1:Int(min(read_len, size)))
        SHA.update!(ctx, nonpadded_view)
        size -= length(nonpadded_view)
        padded_size -= read_len
    end
    @assert size == padded_size == 0
    return bytes2hex(SHA.digest!(ctx))
end

const SKELETON_MAGIC = "%!skeleton:\x83\xe6\xa8\xfe"

function write_skeleton_header(
    skeleton::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    skeleton === devnull || write_extended_header(
        skeleton, type = :g, name = SKELETON_MAGIC, buf = buf,
        ["comment" => "Tar.jl skeleton file", "size" => "0"],
    )
end

function check_skeleton_header(
    skeleton::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    hdr = read_standard_header(skeleton, buf=buf)
    hdr.type == :g && hdr.path == SKELETON_MAGIC ||
        error("not a skeleton file: $skeleton")
    skip_data(skeleton, hdr.size)
end

function read_tarball(
    callback::Function,
    predicate::Function,
    tar::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    skeleton::IO = devnull,
)
    write_skeleton_header(skeleton, buf=buf)
    # symbols for path types except symlinks store the link
    paths = Dict{String,Union{Symbol,String}}()
    globals = Dict{String,String}()
    while !eof(tar)
        hdr = read_header(tar, globals=globals, buf=buf, tee=skeleton)
        hdr === nothing && break
        # check if we should extract or skip
        if !predicate(hdr)
            skip_data(tar, hdr.size)
            continue
        end
        check_header(hdr)
        # normalize path and check for symlink attacks
        path = ""
        for part in split(hdr.path, '/')
            (isempty(part) || part == ".") && continue
            # check_header doesn't allow ".." in path
            get(paths, path, nothing) isa String && error("""
            Refusing to extract path with symlink prefix, possible attack
             * path to extract: $(repr(hdr.path))
             * symlink prefix: $(repr(path))
            """)
            isempty(path) || (paths[path] = :directory)
            path = isempty(path) ? part : "$path/$part"
        end
        paths[path] = hdr.type == :symlink ? hdr.link : hdr.type
        before = applicable(position, tar) ? position(tar) : 0
        callback(hdr, split(path, '/', keepempty=false))
        applicable(position, tar) || continue
        advanced = position(tar) - before
        expected = round_up(hdr.size)
        advanced == expected ||
            error("callback read $advanced bytes instead of $expected")
    end
    return paths
end

function read_header(
    io::IO;
    globals::Dict{String,String} = Dict{String,String}(),
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)
    hdr = read_standard_header(io, buf=buf, tee=tee)
    hdr === nothing && return nothing
    read_header(io, hdr, globals=globals, buf=buf, tee=tee)
end

function read_header(
    io::IO,
    hdr::Header; # initial header
    globals::Dict{String,String} = Dict{String,String}(),
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)
    # process zero or more extended headers
    metadata = copy(globals)
    while true
        if hdr.type in (:g, :x) # POSIX extended headers
            let hdr=hdr         # https://github.com/JuliaLang/julia/issues/15276
                read_extended_metadata(io, hdr.size, buf=buf, tee=tee) do key, val
                    if key in ("size", "path", "linkpath")
                        if hdr.type == :g
                            globals[key] = val
                        end
                        metadata[key] = val
                    end
                end
            end
        elseif hdr.path == "././@LongLink" && hdr.type in (:L, :K)
            # GNU long name or link header
            data = read_data(io, size=hdr.size, buf=buf, tee=tee)
            data[end] == 0 ||
                error("malformed GNU long header (trailing `\\0` expected): " *
                      repr(String(data)))
            key = hdr.type == :L ? "path" : "linkpath"
            metadata[key] = String(@view data[1:end-1])
        else
            break # non-extension header block
        end
        hdr = read_standard_header(io, buf=buf, tee=tee)
        hdr === nothing && throw(EOFError())
    end
    # determine final values for size, path & link
    size = hdr.size
    if "size" in keys(metadata)
        val = metadata["size"]
        size = tryparse(UInt64, val)
        size === nothing &&
            error("invalid extended header size value: $(repr(val))")
    end
    path = get(metadata, "path", hdr.path)
    link = get(metadata, "linkpath", hdr.link)
    # construct and return Header object
    return Header(hdr; path=path, size=size, link=link)
end

using Base.Checked: mul_with_overflow, add_with_overflow

function read_extended_metadata(
    callback::Function,
    io::IO,
    size::Integer;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)
    size > typemax(Int32) &&
        error("read_extended_metadata called with too large size: $size")
    size = Int(size)
    data = read_data(io, size=size, buf=buf, tee=tee)
    malformed() = error("malformed extended header metadata: $(repr(String(data)))")
    i = 0
    while i < size
        j, m = i, 0
        while j ≤ size
            byte = data[j += 1]
            byte == UInt8(' ') && break
            UInt8('0') ≤ byte ≤ UInt8('9') || malformed()
            m, fm = mul_with_overflow(m, 10)
            m, fa = add_with_overflow(m, Int(byte - UInt8('0')))
            fm | fa &&
                error("extended header record size too large: $(repr(String(data)))")
        end
        k, l = j, i + m
        while k ≤ l
            byte = data[k += 1]
            byte == UInt8('=') && break
        end
        # data[i+1:j-1] is the length in decimal
        # data[j+1:k-1] is the key string
        # data[k+1:l-1] is the value string
        # data[i] is end of previous
        # data[j] is ` ` (space)
        # data[k] is `=` (equals)
        # data[l] is `\n` (newline)
        i+1 < j < k < l || malformed()
        @assert data[j] == UInt8(' ')
        @assert data[k] == UInt8('=')
        data[l] == UInt('\n') || malformed()
        i = l # next starting point
        # pass key, value back to caller
        key = String(@view data[j+1:k-1])
        val = String(@view data[k+1:l-1])
        callback(key, val)
    end
end

# For reference see
# https://www.gnu.org/software/tar/manual/html_node/Standard.html

const HEADER_FIELDS = (
    # field, offset, size
    (:name,       0, 100),
    (:mode,     100,   8),
    (:uid,      108,   8),
    (:gid,      116,   8),
    (:size,     124,  12),
    (:mtime,    136,  12),
    (:chksum,   148,   8),
    (:typeflag, 156,   1),
    (:linkname, 157, 100),
    (:magic,    257,   6),
    (:version,  263,   2),
    (:uname,    265,  32),
    (:gname,    297,  32),
    (:devmajor, 329,   8),
    (:devminor, 337,   8),
    (:prefix,   345, 155),
    (:rest,     500,  12),
)

function index_range(field::Symbol)
    for (fld, off, len) in HEADER_FIELDS
        fld == field && return off .+ (1:len)
    end
    error("[internal error] invalid field name: $field")
end

dump_header(buf::AbstractVector{UInt8}) =
    [ fld => String(buf[off .+ (1:len)])
        for (fld, off, len) in HEADER_FIELDS ]

function header_error(buf::AbstractVector{UInt8}, msg::AbstractString)
    sprint() do io
        println(io, msg, "\n[header block data]:")
        for (field, value) in dump_header(buf)
            print(io, "  ", rpad(field, 8), " = ")
            show(io, value)
            println(io)
        end
    end |> error
end

function header_error(buf::AbstractVector{UInt8}, fld::Symbol)
    value = read_header_str(buf, fld)
    header_error(buf, "malformed $fld field: $(repr(value))")
end

function read_standard_header(
    io::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)
    data = read_data(io, size=512, buf=buf, tee=tee)
    # zero block indicates end of tarball
    if all(iszero, data)
        while !eof(io)
            r = readbytes!(io, buf)
            write(tee, view(buf, 1:r))
        end
        return nothing
    end
    # verify valid header
    try
        check_version_field(buf)
        check_checksum_field(buf)
    catch err
        if err isa ErrorException
            msg = match(r"^(.*?)\s*\[header block data\]"s, err.msg).captures[1]
            msg = "This does not appear to be a TAR file/stream — $msg. Note: Tar.jl does not handle decompression; if the tarball is compressed you must use an external command like `gzcat` or package like CodecZlib.jl to decompress it. See the README file for examples."
            err = ErrorException(msg)
        end
        rethrow(err)
    end
    # extract fields we care about
    size = read_header_size(buf)
    name = read_header_str(buf, :name)
    mode = read_header_int(buf, :mode)
    type = read_header_chr(buf, :typeflag)
    link = read_header_str(buf, :linkname)
    prefix = read_header_str(buf, :prefix)
    # check that mode isn't too big
    mode ≤ typemax(typemax(UInt16)) ||
        header_error(buf, "mode value too large: $(string(mode, base=8))")
    # combine prefix & name fields
    path = isempty(prefix) ? name : "$prefix/$name"
    return Header(path, to_symbolic_type(type), mode, size, link)
end

function check_version_field(buf::AbstractVector{UInt8})
    version = read_header_str(buf, :version)
    occursin(r"^0* *$", version) && return
    header_error(buf, "invalid version string for tar file: $(repr(version))")
end

function check_checksum_field(buf::AbstractVector{UInt8})
    chksum = read_header_int(buf, :chksum)
    actual = let r = index_range(:chksum)
        sum(i in r ? UInt8(' ') : buf[i] for i = 1:512)
    end
    chksum == actual && return
    header_error(buf, "incorrect header checksum = $chksum; should be $actual")
end

function read_header_size(buf::AbstractVector{UInt8})
    r = index_range(:size)
    b1 = buf[r[1]] # high bit set for binary
    b1 & 0x80 == 0 && return read_header_int(buf, :size)
    b1 == 0x80 && return read_header_bin(buf, :size, r[1]+1:r[end])
    val = String(buf[r])
    header_error(buf, "binary integer size value too large: $(repr(val))")
end

function read_header_chr(buf::AbstractVector{UInt8}, fld::Symbol)
    r = index_range(fld)
    length(r) == 1 || error("[internal error] not a character field: $fld")
    return Char(buf[first(r)])
end

function read_header_str(buf::AbstractVector{UInt8}, fld::Symbol)
    r = index_range(fld)
    for i in r
        byte = buf[i]
        byte == 0 && return String(buf[first(r):i-1])
    end
    return String(buf[r])
end

function read_header_int(buf::AbstractVector{UInt8}, fld::Symbol)
    r = index_range(fld)
    n = Int64(0)
    before = true
    for i in r
        byte = buf[i]
        before && byte == UInt8(' ') && continue
        byte in (0x00, UInt8(' ')) && break
        UInt8('0') <= byte <= UInt8('7') || header_error(buf, fld)
        if leading_zeros(n) <= 3
            val = String(buf[r])
            header_error(buf, "octal integer $fld value too large: $(repr(val))")
        end
        n <<= 3
        n |= byte - 0x30
        before = false
    end
    before && header_error(buf, fld)
    return n
end

function read_header_bin(
    buf::AbstractVector{UInt8}, fld::Symbol,
    r::UnitRange{<:Integer} = index_range(fld),
)
    n = Int64(0)
    for i in r
        if leading_zeros(n) <= 8
            val = String(buf[r])
            header_error(buf, "binary integer $fld value too large: $(repr(val))")
        end
        n <<= 8
        n |= buf[i]
    end
    return n
end

round_up(size) = 512 * ((size + 511) ÷ 512)

function skip_data(tar::IO, size::Integer)
    size < 0 && throw(ArgumentError("[internal error] negative skip: $size"))
    size > 0 && skip(tar, round_up(size))
end

function read_data(
    tar::IO,
    file::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)::Nothing
    padded_size = round_up(size)
    while padded_size > 0
        max_read_len = Int(min(padded_size, length(buf)))
        read_len = readbytes!(tar, buf, max_read_len)
        write(tee, view(buf, 1:read_len))
        read_len < max_read_len && eof(tar) && throw(EOFError())
        size -= write(file, view(buf, 1:Int(min(read_len, size))))
        padded_size -= read_len
    end
    @assert size == padded_size == 0
    return
end

function read_data(
    tar::IO,
    file::AbstractString;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)::Nothing
    open(file, write=true) do file′
        read_data(tar, file′, size=size, buf=buf, tee=tee)
    end
end

# WARNING: this returns a view into `buf` so you must either use
# the result before making another call using `buf` or make a copy
function read_data(
    tar::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    tee::IO = devnull,
)::AbstractVector{UInt8}
    padded_size = round_up(size)
    padded_size > typemax(Int32) &&
        throw(ArgumentError("read_data(tar; size) called with too large size: $size"))
    padded_size = Int(padded_size)
    length(buf) < padded_size && resize!(buf, nextpow(2, padded_size))
    write(tee, read!(tar, view(buf, 1:padded_size)))
    return view(buf, 1:size)
end

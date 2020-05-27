import SHA

@static if VERSION < v"1.4.0-DEV"
    view_read!(io, buf::SubArray{UInt8}) = readbytes!(io, buf, sizeof(buf))
else
    view_read!(io, buf::SubArray{UInt8}) = read!(io, buf)
end

function list_tarball(
    tar::IO,
    read_hdr::Function = read_standard_header;
    strict::Bool = true,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    headers = Header[]
    while !eof(tar)
        hdr = read_hdr(tar, buf=buf)
        hdr === nothing && break
        strict && check_header(hdr)
        push!(headers, hdr)
        skip_data(tar, hdr.size)
    end
    return headers
end

function extract_tarball(
    predicate::Function,
    tar::IO,
    root::String;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    read_tarball(predicate, tar; buf=buf) do hdr, parts
        # get the file system version of the path
        sys_path = reduce(joinpath, init=root, parts)
        # delete anything that's there already
        ispath(sys_path) && rm(sys_path, force=true, recursive=true)
        # ensure dirname(sys_path) is a directory
        dir = dirname(sys_path)
        st = stat(dir)
        if !isdir(st)
            ispath(st) && rm(dir, force=true, recursive=true)
            mkpath(dir)
        end
        # create the path
        if hdr.type == :directory
            mkdir(sys_path)
        elseif hdr.type == :symlink
            symlink(hdr.link, sys_path)
        elseif hdr.type == :file
            read_data(tar, sys_path, size=hdr.size, buf=buf)
            # set executable bit if necessary
            if !iszero(hdr.mode & 0o100)
                mode = filemode(sys_path)
                # exec bits = read bits, but set user read at least:
                chmod(sys_path, mode | ((mode & 0o444) >> 2) | 0o100)
                # TODO: use actual umask exec bits instead?
            end
        else # should already be caught by check_header
            error("unsupported tarball entry type: $(hdr.type)")
        end
    end
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
            node[name] = Dict{String,Any}()
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
    size::Int,
    HashType::DataType;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    ctx = HashType()
    SHA.update!(ctx, codeunits("blob $size\0"))
    # TODO: this largely duplicates the logic of read_data
    # read_data could be used directly if SHA offered an interface
    # where you write data to an IO object and it maintains a hash
    t = round_up(size)
    while size > 0
        n = min(t, length(buf))
        r = readbytes!(tar, buf, n)
        r < n && eof(io) && error("premature end of tar file")
        v = view(buf, 1:min(r, size))
        SHA.update!(ctx, v)
        size -= length(v)
        t -= r
    end
    @assert size == t == 0
    return bytes2hex(SHA.digest!(ctx))
end

function read_tarball(
    callback::Function,
    predicate::Function,
    tar::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    links = Set{String}()
    while !eof(tar)
        hdr = read_header(tar, buf=buf)
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
            path in links && error("""
            Refusing to extract path with symlink prefix, possible attack
             * symlink prefix: $(repr(path))
             * extracted path: $(repr(hdr.path))
            """)
            path = isempty(path) ? part : "$path/$part"
        end
        if hdr.type == :symlink
            push!(links, path)
        else
            delete!(links, path)
        end
        before = applicable(position, tar) ? position(tar) : 0
        callback(hdr, split(path, '/', keepempty=false))
        applicable(position, tar) || continue
        advanced = position(tar) - before
        expected = round_up(hdr.size)
        advanced == expected ||
            error("callback read $advanced bytes instead of $expected")
    end
end

const IGNORED_EXTENDED_GLOBAL_HEADERS = [
    "charset",
    "comment",
    "gid",
    "gname",
    "hdrcharset",
    "uid",
    "uname",
]

const IGNORED_EXTENDED_LOCAL_HEADERS = [
    "atime",
    "charset",
    "comment",
    "ctime", # not in POSIX standard but emitted by GNU tar in POSIX mode
    "gid",
    "gname",
    "hdrcharset",
    "mtime",
    "uid",
    "uname",
]

function read_header(
    io::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    hdr = read_standard_header(io, buf=buf)
    hdr === nothing && return nothing
    size = path = link = nothing
    while true
        if hdr.type in (:x, :g) # POSIX extended headers
            metadata = read_extended_metadata(io, hdr.size, buf=buf)
            ignored_headers = hdr.type == :x ? IGNORED_EXTENDED_LOCAL_HEADERS :
                                               IGNORED_EXTENDED_GLOBAL_HEADERS
            for (key, value) in metadata
                if hdr.type == :x && key == "size"
                    size = tryparse(UInt64, value)
                    size === nothing &&
                        error("invalid extended header size value: $(repr(value))")
                elseif hdr.type == :x && key == "path"
                    path = value
                elseif hdr.type == :x && key == "linkpath"
                    link = value
                elseif key ∉ ignored_headers
                    error("unexpected extended ($(hdr.type)) header: $(repr(key))")
                end
            end
        elseif hdr.path == "././@LongLink" && hdr.type in (:L, :K)
            # GNU long name or link header
            value = read_data(io, size=hdr.size, buf=buf)
            value[end] == '\0' ||
                error("malformed GNU long header (trailing `\0` expected): $(repr(value))")
            value = chop(value)
            hdr.type == :L && (path = value)
            hdr.type == :K && (link = value)
        else
            break # non-extension header block
        end
        hdr = read_standard_header(io, buf=buf)
        hdr === nothing && error("premature end of tar file")
    end
    return Header(
        something(path, hdr.path),
        hdr.type,
        hdr.mode,
        something(size, hdr.size),
        something(link, hdr.link),
    )
end

using Base.Checked: mul_with_overflow, add_with_overflow

function read_extended_metadata(
    io::IO,
    size::Integer;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    n = readbytes!(io, buf, size)
    n < size && error("premature end of tar file")
    skip(io, mod(512 - n, 512)) # advance to end of block
    malformed() = error("malformed extended header metadata: $(repr(String(buf)))")
    metadata = Pair{String,String}[]
    i = 0
    while i < n
        j, m = i, 0
        while j ≤ n
            byte = buf[j += 1]
            byte == UInt8(' ') && break
            UInt8('0') ≤ byte ≤ UInt8('9') || malformed()
            m, fm = mul_with_overflow(m, 10)
            m, fa = add_with_overflow(m, Int(byte - UInt8('0')))
            fm | fa && error("extended header record size too large: $(repr(buf))")
        end
        k, l = j, i + m
        while k ≤ l
            byte = buf[k += 1]
            byte == UInt8('=') && break
        end
        # buf[i+1:j-1] is the length in decimal
        # buf[j+1:k-1] is the key string
        # buf[k+1:l-1] is the value string
        # buf[i] is end of previous
        # buf[j] is ` ` (space)
        # buf[k] is `=` (equals)
        # buf[l] is `\n` (newline)
        i+1 < j < k < l || malformed()
        @assert buf[j] == UInt8(' ')
        @assert buf[k] == UInt8('=')
        buf[l] == UInt('\n') || malformed()
        @views push!(metadata, String(buf[j+1:k-1]) => String(buf[k+1:l-1]))
        i = l
    end
    return metadata
end

function read_standard_header(
    io::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    header_view = view(buf, 1:512)
    view_read!(io, header_view)
    all(iszero, header_view) && return nothing
    name    = read_header_str(header_view, 0, 100)
    mode    = read_header_int(header_view, 100, 8)
    size    = header_view[124+1] & 0x80 == 0 ?
              read_header_int(header_view, 124, 12) :
              read_header_bin(header_view, 124, 12)
    chksum  = read_header_int(header_view, 148, 8)
    type    = read_header_chr(header_view, 156)
    link    = read_header_str(header_view, 157, 100)
    magic   = read_header_str(header_view, 257, 6)
    version = read_header_str(header_view, 263, 2)
    prefix  = read_header_str(header_view, 345, 155)
    # check various fields
    header_view[index_range(148, 8)] .= ' ' # fill checksum field with spaces
    buf_sum = sum(header_view)
    chksum == buf_sum ||
        error("incorrect header checksum = $chksum; should be $buf_sum\n$(repr(String(header_view)))")
    occursin(r"^ustar\s*$", magic) ||
        error("unknown magic string for tar file: $(repr(magic))")
    occursin(r"^0* *$", version) ||
        error("unknown version string for tar file: $(repr(version))")
    path = isempty(prefix) ? name : "$prefix/$name"
    return Header(path, to_symbolic_type(type), mode, size, link)
end

round_up(size) = 512 * ((size + 511) ÷ 512)

function skip_data(tar::IO, size::Integer)
    skip(tar, round_up(size))
end

index_range(offset::Int, length::Int) = offset .+ (1:length)

read_header_chr(buf::AbstractVector{UInt8}, offset::Int) = Char(buf[offset+1])

function read_header_str(buf::AbstractVector{UInt8}, offset::Int, length::Int)
    r = index_range(offset, length)
    for i in r
        byte = buf[i]
        byte == 0 && return String(buf[first(r):i-1])
    end
    return String(buf[r])
end

function read_header_int(buf::AbstractVector{UInt8}, offset::Int, length::Int)
    n = UInt64(0)
    for i in index_range(offset, length)
        byte = buf[i]
        byte in (0x00, UInt8(' ')) && break
        UInt8('0') <= byte <= UInt8('7') ||
            error("invalid octal digit: $(repr(Char(byte)))")
        n <<= 3
        n |= byte - 0x30
    end
    return n
end

function read_header_bin(buf::AbstractVector{UInt8}, offset::Int, length::Int)
    n = UInt64(0)
    for i in index_range(offset, length)
        n <<= 8
        n |= buf[i]
    end
    return n
end

function read_data(
    tar::IO,
    file::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)::Nothing
    t = round_up(size)
    while size > 0
        n = min(t, length(buf))
        r = readbytes!(tar, buf, n)
        r < n && eof(io) && error("premature end of tar file")
        size -= write(file, view(buf, 1:min(r, size)))
        t -= r
    end
    @assert size == t == 0
    return
end

function read_data(
    tar::IO,
    file::AbstractString;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)::Nothing
    open(file, write=true) do file′
        read_data(tar, file′, size=size, buf=buf)
    end
end

function read_data(
    tar::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)::String
    io = IOBuffer(sizehint=size)
    read_data(tar, io, size=size, buf=buf)
    return String(take!(io))
end

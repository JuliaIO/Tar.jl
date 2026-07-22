struct RewriteEntry
    hdr::Header
    pos::Int64
end

struct RewriteTree
    children::Dict{String, Union{RewriteTree, RewriteEntry}}
end
RewriteTree() = RewriteTree(Dict{String, Union{RewriteTree, RewriteEntry}}())

function create_tarball(
    predicate::Function,
    tar::IO,
    root::String;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    portable::Bool = false,
)
    write_tarball(tar, root, buf=buf) do sys_path, tar_path
        portable && check_windows_path(tar_path)
        hdr = path_header(sys_path, tar_path)
        hdr.type != :directory && return hdr, sys_path
        paths = Dict{String,String}()
        for name in readdir(sys_path)
            sys_path′ = joinpath(sys_path, name)
            predicate(sys_path′) || continue
            paths[name] = sys_path′
        end
        return hdr, paths
    end
end

function recreate_tarball(
    tar::IO,
    root::String,
    skeleton::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    portable::Bool = false,
)
    check_skeleton_header(skeleton, buf=buf)
    globals = Dict{String,String}()
    while !eof(skeleton)
        hdr = read_header(skeleton, globals=globals, buf=buf, tee=tar)
        hdr === nothing && break
        check_header(hdr)
        portable && check_windows_path(hdr.path)
        sys_path = joinpath(root, hdr.path)
        if hdr.type == :file
            write_data(tar, sys_path, size=hdr.size, buf=buf)
        end
    end
end

function rewrite_tarball(
    predicate::Function,
    old_tar::IO,
    new_tar::IO;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
    portable::Bool = false,
)
    tree = RewriteTree()
    read_tarball(predicate, old_tar; buf=buf) do hdr, parts
        portable && check_windows_path(hdr.path, parts)
        isempty(parts) && return
        node = tree
        name = pop!(parts)
        for part in parts
            child = get(node.children, part, nothing)
            if !(child isa RewriteTree)
                child = node.children[part] = RewriteTree()
            end
            node = child
        end
        if hdr.type == :hardlink
            linked = tree
            for part in split(hdr.link, '/')
                linked = linked.children[part]
            end
            entry = linked::RewriteEntry
            hdr′ = Header(entry.hdr, path=hdr.path, mode=hdr.mode)
            node.children[name] = RewriteEntry(hdr′, entry.pos)
        else
            if !(hdr.type == :directory && get(node.children, name, nothing) isa RewriteTree)
                node.children[name] = RewriteEntry(hdr, position(old_tar))
            end
            skip_data(old_tar, hdr.size)
        end
    end
    write_tarball(new_tar, tree, buf=buf) do node, tar_path
        if node isa RewriteTree
            hdr = Header(tar_path, :directory, 0o755, 0, "")
            return hdr, node.children
        else
            entry = node::RewriteEntry
            mode = entry.hdr.type == :file && iszero(entry.hdr.mode & 0o100) ? 0o644 : 0o755
            hdr′ = Header(entry.hdr; path=tar_path, mode=mode)
            data = entry.hdr.type == :directory ? nothing : (old_tar, entry.pos)
            return hdr′, data
        end
    end
end

function write_tarball(
    callback::Function,
    tar::IO,
    sys_path::Any,
    tar_path::String = ".";
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    hdr, data = callback(sys_path, tar_path)::Tuple{Header,Any}
    if hdr.type == :directory
        data isa Union{Nothing, AbstractDict{<:AbstractString}} ||
            error("callback must return a dict of strings, got: $(repr(data))")
    else
        data isa Union{Nothing, AbstractString, IO, Tuple{IO,Integer}} ||
            error("callback must return nothing, string or IO, got: $(repr(data))")
    end
    w = 0
    if tar_path != "."
        w += write_tarball(tar, hdr, data, buf=buf)
    end
    data isa AbstractDict && for name in sort!(collect(keys(data)))
        sys_path′ = data[name]
        tar_path′ = tar_path == "." ? name : "$tar_path/$name"
        w += write_tarball(callback, tar, sys_path′, tar_path′, buf=buf)
    end
    if tar_path == "." && w == 0
        w += write_tarball(tar, hdr, data, buf=buf)
    end
    return w
end

function write_tarball(
    tar::IO,
    hdr::Header,
    data::Any = nothing;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    check_header(hdr)
    w = write_header(tar, hdr, buf=buf)
    if hdr.type == :file
        data isa Union{AbstractString, IO, Tuple{IO,Integer}} ||
            throw(ArgumentError("file record requires path or IO: $(repr(hdr))"))
        w += write_data(tar, data, size=hdr.size, buf=buf)
    end
    return w
end

function write_header(
    tar::IO,
    hdr::Header;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    # extract values
    path = hdr.path
    size = hdr.size
    link = hdr.link

    # check for NULs
    0x0 in codeunits(path) &&
        throw(ArgumentError("path contains NUL bytes: $(repr(path))"))
    0x0 in codeunits(link) &&
        throw(ArgumentError("link contains NUL bytes: $(repr(path))"))

    prefix = ""
    name = path
    w = 0
    # determine if an extended header is needed
    if ncodeunits(link) > 100 || ncodeunits(path) > 100 || size ≥ 68719476736 # 8^12
        extended = Pair{String,String}[]
        # WARNING: don't change the order of these insertions
        # they are inserted and emitted in sorted order by key
        if ncodeunits(link) > 100
            push!(extended, "linkpath" => link)
            link = "" # empty in standard header
        end
        if ncodeunits(path) > 100
            if ncodeunits(path) < 256
                i = findprev('/', path, 100)
                if i !== nothing
                    # try splitting into prefix and name
                    prefix = path[1:prevind(path, i)]
                    name   = path[nextind(path, i):end]
                end
            end
            if ncodeunits(name) > 100 || ncodeunits(prefix) > 155
                push!(extended, "path" => path)
                prefix = name = "" # empty in standard header
            end
        end
        if size ≥ 68719476736 # 8^12
            push!(extended, "size" => string(size))
            # still written in binary in standard header
        end
        # emit extended header if necessary
        if !isempty(extended)
            @assert issorted(extended)
            w += write_extended_header(tar, extended, buf=buf)
        end
    end
    # emit standard header
    std_hdr = link === hdr.link ? hdr : Header(hdr; link=link)
    w += write_standard_header(tar, std_hdr, name=name, prefix=prefix, buf=buf)
end

function write_extended_header(
    tar::IO,
    metadata::Vector{Pair{String,String}};
    type::Symbol = :x, # default: non-global extended header
    name::AbstractString = "",
    prefix::AbstractString = "",
    link::AbstractString = "",
    mode::Integer = 0o000,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    type in (:x, :g) ||
        throw(ArgumentError("invalid type flag for extended header: $(repr(type))"))
    d = IOBuffer()
    for (key, val) in metadata
        entry = " $key=$val\n"
        n = l = ncodeunits(entry)
        while n < l + ndigits(n)
            n = l + ndigits(n)
        end
        @assert n == l + ndigits(n)
        write(d, "$n$entry")
    end
    path = isempty(name) || isempty(prefix) ? "$prefix$name" : "$prefix/$name"
    hdr = Header(path, type, mode, position(d), link)
    w = write_standard_header(tar, hdr, name=name, prefix=prefix, buf=buf)
    w += write_data(tar, seekstart(d), size=hdr.size, buf=buf)
end

# write the bytes of `s` into `buf` at 1-based offset `off`
put_data!(buf::Vector{UInt8}, off::Int, s::String) =
    copyto!(buf, off, codeunits(s), 1, ncodeunits(s))

# write `n` as `pad` zero-padded octal digits at 1-based offset `off` (must fit)
function put_octal!(buf::Vector{UInt8}, off::Int, n::Integer, pad::Int)
    for i in 0:pad-1
        buf[off + pad - 1 - i] = UInt8('0') + ((n >> 3i) % UInt8 & 0x07)
    end
end

function write_standard_header(
    tar::IO,
    hdr::Header;
    name::AbstractString = hdr.path,
    prefix::AbstractString = "",
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    name = String(name)
    prefix = String(prefix)
    type = from_symbolic_type(hdr.type)
    link = hdr.link

    # error checking (presumes checks done by write_header)
    hdr.size < 0 &&
        throw(ArgumentError("negative file size is invalid: $(hdr.size)"))
    ncodeunits(prefix) ≤ 155 ||
        throw(ArgumentError("path prefix too long for standard header: $(repr(prefix))"))
    ncodeunits(name) ≤ 100 ||
        throw(ArgumentError("path name too long for standard header: $(repr(name))"))
    ncodeunits(link) ≤ 100 ||
        throw(ArgumentError("symlink target too long for standard header: $(repr(link))"))
    isascii(type) ||
        throw(ArgumentError("non-ASCII type flag value: $(repr(type))"))

    # construct header block in buf; offsets are 1-based (see HEADER_FIELDS)
    fill!(view(buf, 1:512), 0x00)
    put_data!(buf, 1, name)             # name
    put_octal!(buf, 101, hdr.mode, 6)   # mode (UInt16 always fits in 6 digits)
    buf[107] = UInt8(' ')
    put_data!(buf, 109, "000000 ")      # uid
    put_data!(buf, 117, "000000 ")      # gid
    if hdr.size < 8589934592            # 8^11: 11 octal digits and a space
        put_octal!(buf, 125, hdr.size, 11)
        buf[136] = UInt8(' ')
    elseif hdr.size < 68719476736       # 8^12: 12 octal digits, no space
        put_octal!(buf, 125, hdr.size, 12)
    else
        # emulate GNU tar: write binary size with leading bit set
        # can encode up to 2^95; Int64 size field only up to 2^63-1
        buf[125] = 0x80 | ((hdr.size >> (8*11)) % UInt8)
        for i = 10:-1:0
            buf[136 - i] = (hdr.size >> 8i) % UInt8
        end
    end
    put_data!(buf, 137, "00000000000 ") # mtime
    # chksum @ 149-156: computed once the rest is written
    buf[157] = UInt8(type)              # typeflag
    put_data!(buf, 158, link)           # linkname
    put_data!(buf, 258, "ustar")        # magic (NUL-terminated by fill!)
    put_data!(buf, 264, "00")           # version
    # uname & gname: NULs from fill!
    put_data!(buf, 330, "000000 ")      # devmajor
    put_data!(buf, 338, "000000 ")      # devminor
    put_data!(buf, 346, prefix)         # prefix

    # header block checksum: computed as if chksum field were spaces
    b = view(buf, 1:512)
    chksum = sum(b) + UInt32(' ') * 8
    put_octal!(buf, 149, chksum, 6)     # ≤ 512×0xff, always fits in 6 digits
    buf[155] = 0x00
    buf[156] = UInt8(' ')

    # write header block
    w = write(tar, b)
    @assert w == 512
    return w
end

function write_data(
    tar::IO,
    data::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    size < 0 &&
        throw(ArgumentError("cannot write negative data: $size"))
    w, t = 0, round_up(size)
    while size > 0
        b = Int(min(size, length(buf)))::Int
        n = Int(readbytes!(data, buf, b))::Int
        n < b && eof(data) && throw(EOFError())
        w += write(tar, view(buf, 1:n))
        size -= n
        t -= n
    end
    @assert size == 0
    @assert 0 ≤ t < 512
    t > 0 && (w += write(tar, fill!(view(buf, 1:t), 0)))
    return w
end

function write_data(
    tar::IO,
    (data, pos)::Tuple{IO,Integer};
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    seek(data, pos)
    write_data(tar, data, size=size, buf=buf)
end

function write_data(
    tar::IO,
    file::String;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    open(file) do data
        write_data(tar, data, size=size, buf=buf)
        eof(data) || error("data file too large: $data")
    end
end

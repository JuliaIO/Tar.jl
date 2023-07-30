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
    tree = Dict{String,Any}()
    read_tarball(predicate, old_tar; buf=buf) do hdr, parts
        portable && check_windows_path(hdr.path, parts)
        isempty(parts) && return
        node = tree
        name = pop!(parts)
        for part in parts
            node′ = get(node, part, nothing)
            if !(node′ isa Dict)
                node′ = node[part] = Dict{String,Any}()
            end
            node = node′
        end
        if hdr.type == :hardlink
            node′ = tree
            for part in split(hdr.link, '/')
                node′ = node′[part]
            end
            hdr′ = Header(node′[1], path=hdr.path, mode=hdr.mode)
            node[name] = (hdr′, node′[2])
        else
            if !(hdr.type == :directory && get(node, name, nothing) isa Dict)
                node[name] = (hdr, position(old_tar))
            end
            skip_data(old_tar, hdr.size)
        end
    end
    write_tarball(new_tar, tree, buf=buf) do node, tar_path
        if node isa Dict
            hdr = Header(tar_path, :directory, 0o755, 0, "")
            return hdr, node
        else
            hdr, pos = node
            mode = hdr.type == :file && iszero(hdr.mode & 0o100) ? 0o644 : 0o755
            hdr′ = Header(hdr; path=tar_path, mode=mode)
            data = hdr.type == :directory ? nothing : (old_tar, pos)
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

    # determine if an extended header is needed
    extended = Pair{String,String}[]
    # WARNING: don't change the order of these insertions
    # they are inserted and emitted in sorted order by key
    if ncodeunits(link) > 100
        push!(extended, "linkpath" => link)
        link = "" # empty in standard header
    end
    prefix = ""
    name = path
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
    w = 0
    if !isempty(extended)
        @assert issorted(extended)
        w += write_extended_header(tar, extended, buf=buf)
    end
    # emit standard header
    std_hdr = Header(hdr; link=link)
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

    # octal strings for size and mode
    m = string(hdr.mode, base=8, pad=6)
    s = string(hdr.size, base=8, pad=11)

    # error checking (presumes checks done by write_header)
    hdr.size < 0 &&
        throw(ArgumentError("negative file size is invalid: $(hdr.size)"))
    ncodeunits(prefix) ≤ 155 ||
        throw(ArgumentError("path prefix too long for standard header: $(repr(prefix))"))
    ncodeunits(name) ≤ 100 ||
        throw(ArgumentError("path name too long for standard header: $(repr(name))"))
    ncodeunits(link) ≤ 100 ||
        throw(ArgumentError("symlink target too long for standard header: $(repr(link))"))
    ncodeunits(m) ≤ 6 ||
        throw(ArgumentError("mode too large for standard header: 0o$m"))
    isascii(type) ||
        throw(ArgumentError("non-ASCII type flag value: $(repr(type))"))

    # construct header block
    buf[1:512] .= 0x00
    h = IOBuffer(buf, write=true, truncate=false)
    write(h, name)              # name
    seek(h, 100)
    write(h, "$m \0")           # mode
    write(h, "000000 \0")       # uid
    write(h, "000000 \0")       # gid
    if ncodeunits(s) ≤ 12       # size
        write(h, s)
        if ncodeunits(s) < 12
            write(h, ' ')
        end
    else
        # emulate GNU tar: write binary size with leading bit set
        # can encode up to 2^95; Int64 size field only up to 2^63-1
        write(h, 0x80 | ((hdr.size >> (8*11)) % UInt8))
        for i = 10:-1:0
            write(h, (hdr.size >> 8i) % UInt8)
        end
    end
    write(h, "00000000000 ")    # mtime
    write(h, "        ")        # chksum (blank)
    write(h, type)              # typeflag
    @assert position(h) == 157
    write(h, link)              # linkname
    seek(h, 257)
    write(h, "ustar\0")         # magic
    write(h, "00")              # version
    skip(h, 64)                 # uname & gname
    write(h, "000000 \0")       # devmajor
    write(h, "000000 \0")       # devminor
    @assert position(h) == 345
    write(h, prefix)            # prefix
    @assert position(h) <= 512

    # fix header block checksum
    b = view(buf, 1:512)
    c = string(sum(b), base=8, pad=6)
    @assert ncodeunits(c) <= 6
    seek(h, 148)
    write(h, "$c\0 ")
    @assert position(h) == 156

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

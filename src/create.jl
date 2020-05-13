@static if VERSION < v"1.4.0-DEV"
    sorted_readdir(args...) = sort!(readdir(args...))
else
    sorted_readdir(args...) = readdir(args...)
end

function create_tarball(
    predicate::Function,
    tar::IO,
    sys_path::String,       # path in the filesystem
    tar_path::String = "."; # path in the tarball
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    w = 0
    hdr = path_header(sys_path, tar_path)
    if hdr.type == :directory
        for name in sorted_readdir(sys_path)
            sys_path′ = joinpath(sys_path, name)
            predicate(sys_path′) || continue
            tar_path′ = tar_path == "." ? name : "$tar_path/$name"
            w += create_tarball(predicate, tar, sys_path′, tar_path′, buf=buf)
        end
    end
    if hdr.type != :directory || w == 0
        w += write_tarball(tar, hdr, sys_path, buf=buf)
    end
    @assert w > 0
    return w
end

function write_tarball(
    tar::IO,
    hdr::Header,
    data::Union{Nothing, AbstractString, IO} = nothing;
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    # error checks
    check_header(hdr)
    hdr.type != :file || data !== nothing ||
        throw(ArgumentError("data required for file record: $(repr(hdr))"))

    # write tarball header & data
    w = write_header(tar, hdr, buf=buf)
    if hdr.type == :file
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
    if ncodeunits(path) > 100
        if ncodeunits(path) < 256 && (i = findprev('/', path, 100)) !== nothing
            # try splitting into prefix and name
            prefix = path[1:prevind(path, i)]
            name   = path[nextind(path, i):end]
        end
        if ncodeunits(name) > 100 || ncodeunits(prefix) > 155
            push!(extended, "path" => path)
            prefix = name = "" # empty in standard header
        end
    end
    if size ≥ 8^12
        push!(extended, "size" => String(size))
        # still written in binary in standard header
    end

    # emit extended header if necessary
    w = 0
    if !isempty(extended)
        @assert issorted(extended)
        w += write_extended_header(tar, extended, buf=buf)
    end
    # emit standard header
    std_hdr = Header(hdr.path, hdr.type, hdr.mode, hdr.size, link)
    w += write_standard_header(tar, std_hdr, name=name, prefix=prefix, buf=buf)
end

function write_extended_header(
    tar::IO,
    metadata::Vector{Pair{String,String}};
    type::Symbol = :x, # default: non-global extended header
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    type in (:x, :g) ||
        throw(ArgumentError("invalid type flag for extended header: $(repr(type))"))
    d = IOBuffer()
    for (key, val) in metadata
        isvalid(key) ||
            throw(ArgumentError("extended header key not valid UTF-8: $(repr(key))"))
        isvalid(val) ||
            throw(ArgumentError("extended header value not valid UTF-8: $(repr(val))"))
        # generate key-value entry
        entry = " $key=$val\n"
        n = l = ncodeunits(entry)
        while n < l + ndigits(n)
            n = l + ndigits(n)
        end
        @assert n == l + ndigits(n)
        write(d, "$n$entry")
    end
    hdr = Header("", type, 0o000, position(d), "")
    w = write_standard_header(tar, hdr, buf=buf)
    w += write_data(tar, seekstart(d), size=hdr.size, buf=buf)
end

function write_standard_header(
    tar::IO,
    hdr::Header;
    name::AbstractString = "",
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
    hdr.size < 0 &&
        throw(ArgumentError("negative file size is invalid: $(hdr.size)"))
    ncodeunits(prefix) ≤ 155 ||
        throw(ArgumentError("path prefix too long for standard header: $(repr(prefix))"))
    ncodeunits(name) ≤ 100 ||
        throw(ArgumentError("path name too long for standard header: $(repr(name))"))
    ncodeunits(link) ≤ 100 ||
        throw(ArgumentError("symlink target too long for standard header: $(repr(link))"))
    ncodeunits(m) ≤ 6 ||
        throw(ArgumentError("mode too large for standard header: 0o$m"))
    ncodeunits(s) ≤ 12 ||
        isempty(name) && isempty(prefix) || # after extended header, large size ok
        throw(ArgumentError("size too large for standard header: $size (0o$s)"))
    isascii(type) ||
        throw(ArgumentError("non-ASCII type flag value: $(repr(type))"))

    # construct header block
    header_view = view(buf, 1:512)
    h = IOBuffer(fill!(header_view, 0x00), write=true, truncate=false)
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
        @assert isempty(name) && isempty(prefix) # after extended header
        # emulate GNU tar: write binary size with leading bit set
        write(h, 0x80 | ((size >> (8*11)) % UInt8))
        for i = 10:-1:0
            write(h, (size >> 8i) % UInt8)
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

    # fix the checksum
    c = string(sum(header_view), base=8, pad=6)
    @assert ncodeunits(c) ≤ 6
    seek(h, 148)
    write(h, "$c\0 ")
    @assert position(h) == 156

    # write header
    w = write(tar, header_view)
    @assert w == 512
    return w
end

function write_data(
    tar::IO,
    data::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    w = s = 0
    @assert sizeof(buf) % 512 == 0
    while !eof(data)
        s += n = readbytes!(data, buf)
        if n < sizeof(buf)
            r = n % 512
            if r != 0
                pad = n - r + 512
                buf[n+1:pad] .= 0
                n = pad
            end
            w += write(tar, view(buf, 1:n))
        else
            w += write(tar, buf)
        end
    end
    s == size || error("""
    data did not have the expected size:
     - got: $s
     - expected: $size
    while extracting tar data from $data.
    """)
    return w
end

function write_data(
    tar::IO,
    file::String;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, DEFAULT_BUFFER_SIZE),
)
    open(file) do data
        write_data(tar, data, size=size, buf=buf)
    end
end

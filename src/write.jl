function write_tar(
    predicate::Function,
    out::IO,
    sys_path::String,      # path in the filesystem
    tar_path::String = ""; # path in the tarball
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    w = 0
    st = lstat(sys_path)
    files = Tuple{String,String}[]
    if islink(st)
        size = 0
        type = '2'
        mode = 0o755
        link = readlink(sys_path)
    elseif isfile(st)
        size = filesize(st)
        type = '0'
        # TODO: git's executable criteria w/r/t user, group, other?
        mode = iszero(filemode(st) & 0o111) ? 0o644 : 0o755
        link = ""
    elseif isdir(st)
        size = 0
        type = '5'
        mode = 0o755
        link = ""
        for name in readdir(sys_path, sort = false)
            path = joinpath(sys_path, name)
            predicate(path) || continue
            isdir(path) && (name = "$name/")
            push!(files, (name, path))
        end
    else
        error("unsupported file type: $(repr(sys_path))")
    end
    if isempty(files) # non-empty directories are implicit
        path = isempty(tar_path) ? "." : tar_path
        w += write_header(out, path, size=size, type=type, mode=mode, link=link, buf=buf)
        size > 0 && (w += write_data(out, sys_path, size=size, buf=buf))
    end
    for (name, path) in sort!(files)
        w += write_tar(predicate, out, path, tar_path * name)
    end
    return w
end

function write_tar(
    out::IO,
    sys_path::String,
    tar_path::String = "";
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    write_tar(p->true, out, sys_path, tar_path, buf=buf)
end

function write_header(
    out::IO,
    path::AbstractString;
    size::Integer,
    type::Char = '0',
    mode::Integer = 0o644,
    link::AbstractString = "",
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    path = String(path)
    link = String(link)

    # error checking
    size < 0 && throw(ArgumentError("negative file size is invalid: $size"))
    path == "." && type != '5' &&
        throw(ArgumentError("path '.' must be a directory; got type $(repr(type))"))
    check_paths(path, link)

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
        w += write_extended_header(out, extended, buf=buf)
    end
    # emit standard header
    w += write_standard_header(
        out, name=name, prefix=prefix, size=size,
        type=type, mode=mode, link=link, buf=buf,
    )
end

function check_paths(path::String, link::String)
    # checks for both path and link
    for (x, p) in (("path", path), ("link", link))
        !isempty(p) && p[1] == '/' &&
            throw(ArgumentError("$x may not be absolute: $(repr(p))"))
        occursin("//", p) &&
            throw(ArgumentError("$x may not have conscutive slashes: $(repr(p))"))
        0x0 in codeunits(p) &&
            throw(ArgumentError("$x may not contain NUL bytes: $(repr(p))"))
    end
    # checks for path only
    isempty(path) &&
        throw(ArgumentError("path may not be empty: $(repr(path))"))
    path != "." && occursin(r"(^|/)\.\.?(/|$)", path) &&
        throw(ArgumentError("path may not have '.' or '..' components: $(repr(path))"))
    # checks for link only
    if !isempty(link)
        dir = dirname(path)
        fullpath = isempty(dir) ? link : "$dir/$link"
        level = count("/", fullpath) + 1
        level -= count(r"(^|/)\.(/|$)", fullpath)
        level -= count(r"(^|/)\.\.(/|$)", fullpath) * 2
        level < 0 &&
            throw(ArgumentError("link may not point above root: $(repr(fullpath))"))
    end
end

function write_extended_header(
    out::IO,
    metadata::Vector{Pair{String,String}};
    type::Char = 'x',
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    type in "xg" ||
        throw(ArgumentError("invalid type flag for extended header: $(repr(type))"))
    d = IOBuffer()
    for (key, value) in metadata
        isvalid(key) ||
            throw(ArgumentError("extended header key not valid UTF-8: $(repr(key))"))
        isvalid(value) ||
            throw(ArgumentError("extended header value not valid UTF-8: $(repr(value))"))
        # generate key-value entry
        entry = " $key=$value\n"
        n = l = ncodeunits(entry)
        while n < l + ndigits(n)
            n = l + ndigits(n)
        end
        @assert n == l + ndigits(n)
        write(d, "$n$entry")
    end
    n = position(d)
    w = write_standard_header(out, size=n, type=type, buf=buf)
    w += write_data(out, seekstart(d), size=n, buf=buf)
end

function write_standard_header(
    out::IO;
    name::AbstractString = "",
    prefix::AbstractString = "",
    size::Integer = 0,
    type::Char = '0',
    mode::Integer = 0o000,
    link::AbstractString = "",
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    name = String(name)
    prefix = String(prefix)
    link = String(link)

    # octal strings for size and mode
    s = string(size, base=8, pad=11) :: String
    m = string(mode, base=8, pad=6) :: String

    # error checking (presumes checks done by write_header)
    size < 0 &&
        throw(ArgumentError("negative file size is invalid: $size"))
    ncodeunits(prefix) ≤ 155 ||
        throw(ArgumentError("path prefix too long for standard header: $(repr(prefix))"))
    ncodeunits(name) ≤ 100 ||
        throw(ArgumentError("path name too long for standard header: $(repr(name))"))
    ncodeunits(link) ≤ 100 ||
        throw(ArgumentError("symlink target too long for standard header: $(repr(link))"))
    ncodeunits(s) ≤ 12 ||
        isempty(name) && isempty(prefix) || # after extended header, large size ok
        throw(ArgumentError("size too large for standard header: $size (0o$s)"))
    ncodeunits(m) ≤ 6 ||
        throw(ArgumentError("mode too large for standard header: 0o$m"))
    isascii(type) ||
        throw(ArgumentError("non-ASCII type flag value: $(repr(type))"))

    # construct header block
    resize!(buf, 512)
    h = IOBuffer(fill!(buf, 0x00), write=true, truncate=false)
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
    c = string(sum(buf), base=8, pad=6) :: String
    @assert ncodeunits(c) ≤ 6
    seek(h, 148)
    write(h, "$c\0 ")
    seek(h, 512)

    # write header
    w = write(out, buf)
    @assert w == 512
    return w
end

function write_data(
    out::IO,
    from::IO;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    resize!(buf, 512)
    w = s = 0
    while !eof(from)
        s += n = readbytes!(from, buf)
        n < 512 && (buf[n+1:512] .= 0)
        w += write(out, buf)
    end
    s == size ||
        throw(@error("data did not have the expected size",
            got = s, expected = size, source = from))
    return w
end

function write_data(
    out::IO,
    from::String;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    open(from) do data
        write_data(out, data, size=size, buf=buf)
    end
end

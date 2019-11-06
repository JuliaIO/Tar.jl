"""
The `Header` type is a struct representing the essential metadata for a single
record in a tar file with this definition:

    struct Header
        path :: String # path relative to the root
        type :: Symbol # type indicator (see below)
        mode :: UInt16 # mode/permissions (best viewed in octal)
        size :: Int64  # size of record data in bytes
        link :: String # target path of a symlink
    end

Types are represented with the following symbols: `file`, `hardlink`, `symlink`,
`chardev`, `blockdev`, `directory`, `fifo`, or for unkonwn types, the typeflag
character as a symbol. Note that [`extract`](@ref) refuses to extract records
types other than `file`, `symlink` and `directory`; [`list`](@ref) will only
list other kinds of records if called with `strict=false`.

The tar format includes various other metadata about records, including user and
group IDs, user and group names, and timestamps. The `Tar` package, by design,
completely ignores these. When creating tar files, these fields are always set
to zero/empty. When reading tar files, these fields are ignored aside from
verifying header checksums for each header record for all fields.
"""
struct Header
    path::String
    type::Symbol
    mode::UInt16
    size::Int64
    link::String
end

function Base.show(io::IO, hdr::Header)
    show(io, Header)
    print(io, "(")
    show(io, hdr.path)
    print(io, ", ")
    show(io, hdr.type)
    print(io, ", 0o", string(hdr.mode, base=8, pad=3), ", ")
    show(io, hdr.size)
    print(io, ", ")
    show(io, hdr.link)
    print(io, ")")
end

function symbolic_type(type::Char)
    type == '0'     ? :file      :
    type == '1'     ? :hardlink  :
    type == '2'     ? :symlink   :
    type == '3'     ? :chardev   :
    type == '4'     ? :blockdev  :
    type == '5'     ? :directory :
    type == '6'     ? :fifo      : Symbol(type)
end

function check_header(hdr::Header)
    hdr.path == "." && hdr.type != :directory &&
        throw(@error("path '.' not a directory", type=hdr.type))
    hdr.type in (:file, :directory, :symlink) ||
        throw(@error("unsupported file type", path=hdr.path, type=hdr.type))
    hdr.type != :symlink && !isempty(hdr.link) &&
        throw(@error("non-link with link path", path=hdr.path, link=hdr.link))
    hdr.type == :symlink && hdr.size != 0 &&
        throw(@error("symlink with non-zero size", path=hdr.path, size=hdr.size))
    hdr.type == :directory && hdr.size != 0 &&
        throw(@error("directory with non-zero size", path=hdr.path, size=hdr.size))
    hdr.type != :directory && !isempty(hdr.path) && hdr.path[end] == '/' &&
        throw(@error("non-directory ending with '/'", path=hdr.path, type=hdr.type))
    check_paths(hdr.path, hdr.link)
end

# used by check_header and write_header
function check_paths(path::String, link::String)
    # checks for both path and link
    for (x, p) in (("path", path), ("link", link))
        !isempty(p) && p[1] == '/' &&
            error("$x is absolute: $(repr(p))")
        occursin("//", p) &&
            error("$x has conscutive slashes: $(repr(p))")
        0x0 in codeunits(p) &&
            error("$x contains NUL bytes: $(repr(p))")
    end
    # checks for path only
    isempty(path) &&
        error("path is empty")
    path != "." && occursin(r"(^|/)\.\.?(/|$)", path) &&
        error("path has '.' or '..' components: $(repr(path))")
    # checks for link only
    if !isempty(link)
        dir = dirname(path)
        fullpath = isempty(dir) ? link : "$dir/$link"
        level = count("/", fullpath) + 1
        level -= count(r"(^|/)\.(/|$)", fullpath)
        level -= count(r"(^|/)\.\.(/|$)", fullpath) * 2
        level < 0 &&
            throw(@error("link points above root", path=path, link=link))
    end
end

function list_tarball(
    tar::IO;
    strict::Bool = true,
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    headers = Header[]
    while !eof(tar)
        hdr = read_header(tar, buf=buf)
        hdr === nothing && break
        strict && check_header(hdr)
        push!(headers, hdr)
        skip(tar, 512 * ((hdr.size + 511) ÷ 512))
    end
    return headers
end

function extract_tarball(
    tar::IO,
    root::String;
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    while !eof(tar)
        hdr = read_header(tar, buf=buf)
        hdr === nothing && break
        check_header(hdr)
        # create the path
        path = hdr.path[end] == '/' ? chop(hdr.path) : hdr.path
        path = joinpath(root, split(path, '/')...)
        if hdr.type == :directory
            mkpath(path)
        else
            if ispath(path)
                # delete and replace path
                rm(path, force=true, recursive=true)
            else
                dir = dirname(path)
                # ensure `dir` is a directory
                st = stat(dir)
                if !isdir(st)
                    ispath(st) && rm(dir, force=true, recursive=true)
                    mkpath(dir)
                end
            end
            hdr.type == :file && read_data(tar, path, size=hdr.size)
            hdr.type == :symlink && symlink(hdr.link, path)
        end
        if hdr.type != :symlink
            chmod(path, hdr.mode)
        elseif Sys.isbsd()
            # BSD system support symlink permissions, so try setting them...
            ret = ccall(:lchmod, Cint, (Cstring, Base.Cmode_t), path, hdr.mode)
            systemerror(:lchmod, ret != 0)
        end
    end
end

function read_header(io::IO; buf::Vector{UInt8} = Vector{UInt8}(undef, 512))
    hdr = read_standard_header(io, buf=buf)
    hdr === nothing && return nothing
    hdr.type in (:x, :g) || return hdr
    size = path = link = nothing
    metadata = read_extended_metadata(io, hdr.size, buf=buf)
    for (key, value) in metadata
        if key == "size"
            size = tryparse(UInt64, value)
            size === nothing &&
                error("invalid extended header size value: $(repr(value))")
        elseif key == "path"
            path = value
        elseif key == "linkpath"
            link = value
        end
    end
    hdr = read_standard_header(io, buf=buf)
    hdr === nothing && error("premature end of tar file")
    return Header(
        something(path, hdr.path),
        hdr.type, hdr.mode,
        something(size, hdr.size),
        something(link, hdr.link),
    )
end

using Base.Checked: mul_with_overflow, add_with_overflow

function read_extended_metadata(
    io::IO,
    size::Integer;
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    n = readbytes!(io, buf, size)
    n < size && "premature end of tar file"
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

function read_standard_header(io::IO; buf::Vector{UInt8} = Vector{UInt8}(undef, 512))
    resize!(buf, 512)
    read!(io, buf)
    all(iszero, buf) && return nothing
    n = length(buf)
    n == 0 && error("premature end of tar file")
    n < 512 && error("incomplete trailing block with length $n < 512")
    @assert n == 512
    name    = read_header_str(buf, 0, 100)
    mode    = read_header_int(buf, 100, 8)
    size    = buf[124+1] & 0x80 == 0 ?
              read_header_int(buf, 124, 12) :
              read_header_bin(buf, 124, 12)
    chksum  = read_header_int(buf, 148, 8)
    type    = read_header_chr(buf, 156)
    link    = read_header_str(buf, 157, 100)
    magic   = read_header_str(buf, 257, 6)
    version = read_header_str(buf, 263, 2)
    prefix  = read_header_str(buf, 345, 155)
    # check various fields
    buf[index_range(148, 8)] .= ' ' # fill checksum field with spaces
    buf_sum = sum(buf)
    chksum == buf_sum ||
        error("incorrect header checksum = $chksum; should be $buf_sum\n$(repr(String(buf)))")
    magic == "ustar" ||
        error("unknown magic string for tar file: $(repr(magic))")
    version == "00" ||
        error("unkonwn version string for tar file: $(repr(version))")
    isascii(type) ||
        error("invalid block type indicator: $(repr(type))")
    path = isempty(prefix) ? name : "$prefix/$name"
    return Header(path, symbolic_type(type), mode, size, link)
end

index_range(offset::Int, length::Int) = offset .+ (1:length)

read_header_chr(buf::Vector{UInt8}, offset::Int) = Char(buf[offset+1])

function read_header_str(buf::Vector{UInt8}, offset::Int, length::Int)
    r = index_range(offset, length)
    for i in r
        byte = buf[i]
        byte == 0 && return String(buf[first(r):i-1])
    end
    return String(buf[r])
end

function read_header_int(buf::Vector{UInt8}, offset::Int, length::Int)
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

function read_header_bin(buf::Vector{UInt8}, offset::Int, length::Int)
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
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    resize!(buf, 512)
    while size > 0
        r = readbytes!(tar, buf)
        r < 512 && eof(io) && error("premature end of tar file")
        size < 512 && resize!(buf, size)
        size -= write(file, buf)
    end
    resize!(buf, 512)
    @assert size == 0
    return
end

function read_data(
    tar::IO,
    file::String;
    size::Integer,
    buf::Vector{UInt8} = Vector{UInt8}(undef, 512),
)
    open(file, write=true) do file′
        read_data(tar, file′, size=size, buf=buf)
    end
end

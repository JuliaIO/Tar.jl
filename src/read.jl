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
    occursin(r"^ustar\s*$", magic) ||
        error("unknown magic string for tar file: $(repr(magic))")
    occursin(r"^0* *$", version) ||
        error("unkonwn version string for tar file: $(repr(version))")
    isascii(type) ||
        error("invalid block type indicator: $(repr(type))")
    path = isempty(prefix) ? name : "$prefix/$name"
    return Header(path, to_symbolic_type(type), mode, size, link)
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

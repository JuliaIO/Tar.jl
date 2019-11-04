function read_standard_header(io::IO; buf::Vector{UInt8} = Vector{UInt8}(undef, 512))
    resize!(buf, 512)
    read!(io, buf)
    n = length(buf)
    n == 0 && error("premature end of tarball")
    n < 512 && error("incomplete trailing block with length $n < 512")
    @assert n == 512
    name    = read_header_str(buf, 0, 100)
    mode    = read_header_int(buf, 100, 8)
    size    = read_header_int(buf, 124, 12)
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
        error("incorrect checksum $chksum for block; should be $buf_sum")
    magic == "ustar" ||
        error("unknown magic string for tar file: $(repr(magic))")
    version == "00" ||
        error("unkonwn version string for tar file: $(repr(version))")
    isascii(type) ||
        error("invalid block type indicator: $(repr(type))")
    path = isempty(prefix) ? name : "$prefix/$name"
    return (
        path = path,
        mode = mode,
        size = size,
        type = type,
        link = link,
    )
end

index_range(offset::Int, length::Int) = offset .+ (1:length)

read_header_chr(block::Vector{UInt8}, offset::Int) = Char(block[offset+1])

function read_header_str(block::Vector{UInt8}, offset::Int, length::Int)
    r = index_range(offset, length)
    for i in r
        byte = block[i]
        byte == 0 && return String(block[first(r):i-1])
    end
    return String(block[r])
end

function read_header_int(block::Vector{UInt8}, offset::Int, length::Int)
    n = 0
    for i in index_range(offset, length)
        byte = block[i]
        UInt8('0') <= byte <= UInt8('7') || break
        n <<= 3
        n += byte - 0x30
    end
    return n
end

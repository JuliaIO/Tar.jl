const FIELDS = Dict(
    :name       => (String,   0, 100),
    :mode       => (Int,    100,   8),
    :uid        => (Int,    108,   8),
    :gid        => (Int,    116,   8),
    :size       => (Int,    124,  12),
    :mtime      => (Int,    136,  12),
    :chksum     => (Int,    148,   8),
    :typeflag   => (Char,   156,   1),
    :linkname   => (String, 157, 100),
    :magic      => (String, 257,   6),
    :version    => (String, 263,   2),
    :uname      => (String, 265,  32),
    :gname      => (String, 297,  32),
    :devmajor   => (Int,    329,   8),
    :devminor   => (Int,    337,   8),
    :prefix     => (String, 345, 155),
)

function field_data(buf::Vector{UInt8}, field::Symbol)
    type, offset, len = FIELDS[field]
    return String(buf[offset .+ (1:len)])
end

function parse_header(buf::Vector{UInt8})
    Dict(f => field_data(buf, f) for f in keys(FIELDS))
end

function unsupported_file_type(options::Options, sys_path)
    msg = "unsupported file type: $(repr(sys_path))"
    if options.unsupported_file_type == :warn
        @warn(msg)
    else
        throw(ErrorException(msg))
    end
    return nothing
end

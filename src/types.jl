struct Options
    unsupported_file_type::Symbol

    function Options(;
            unsupported_file_type::Symbol = :error,
        )
        if (unsupported_file_type !== :error) && (unsupported_file_type !== :warn)
            msg = "unsupported_file_type must be either :error or :warn"
            throw(ArgumentError(msg))
        end
        options = new(
            unsupported_file_type,
        )
        return options
    end
end

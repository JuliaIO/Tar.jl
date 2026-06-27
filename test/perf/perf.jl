using Random, Tar, Printf, BenchmarkTools
import TranscodingStreams: TranscodingStream
import CodecZlib: GzipCompressor

function fill_tree!(root::String, depth::Int, max_dirs::Int, num_files::Int, file_size::Int)
    if depth <= 0
        return
    end

    # First, create files
    for file_idx in 1:num_files
        fname = randstring(rand(5:20))
        open(joinpath(root, fname), "w") do io
            write(io, rand(UInt8, file_size))
        end
    end

    # Next, create directories and recurse
    for dir_idx in 1:max_dirs
        dname = joinpath(root, randstring(rand(5:20)))
        mkdir(dname)
        fill_tree!(dname, depth-1, max_dirs, num_files, file_size)
    end
end


function many_small_files(dir, depth=3, max_dirs=3, num_files=1000, file_size=1000)
    fill_tree!(dir, depth, max_dirs, num_files, file_size)
end
function some_medium_files(dir, depth=2, max_dirs=3, num_files=20, file_size=5*1000*1000)
    fill_tree!(dir, depth, max_dirs, num_files, file_size)
end
function few_large_files(dir, depth=1, max_dirs=2, num_files=3, file_size=100*1000*1000)
    fill_tree!(dir, depth, max_dirs, num_files, file_size)
end

function time_tar(genfunc::Function; kwargs...)
    mktempdir() do dir
        t_gen = @elapsed genfunc(dir; kwargs...)
        mktempdir() do outdir
            # First, test performance of bundling up just tar
            tarjl_out = joinpath(outdir, "out_tarjl.tar")
            tar_out = joinpath(outdir, "out_tar.tar")
            t_create_tarjl = @benchmark Tar.create($(dir), $(tarjl_out))
            t_create_tar = cd(dir) do
                @benchmark run($(`tar -cf $(tar_out) .`))
            end

            s_tarjl = filesize(tarjl_out)
            s_tar = filesize(tar_out)

            t_list_tarjl = @benchmark Tar.list($(tarjl_out))
            t_list_tar = @benchmark Tar.list($(tar_out))

            # Next, test performance of tar + gzip in all three configurations:
            # Tar.jl piped into gzip
            # Tar.jl chained into GzipCompressor
            # tar with -z
            tarjl_codec_out = joinpath(outdir, "out_tarjl_codec.tar.gz")
            tarjl_gzip_out = joinpath(outdir, "out_tarjl_gzip.tar.gz")
            tar_gzip_out = joinpath(outdir, "out_tar_gzip.tar.gz")
            t_create_tarjl_codec = @benchmark open($(tarjl_codec_out), "w") do io
                Tar.create($(dir), TranscodingStream(GzipCompressor(), io))
            end
            
            t_create_tarjl_gzip = @benchmark begin 
                gzip_proc = open(pipeline(`gzip - `, stdout=$(tarjl_gzip_out)); write=true)
                Tar.create($(dir), gzip_proc)
                close(gzip_proc.in)
            end
            t_create_tar_gzip = cd(dir) do
                @benchmark run($(`tar -czf $(tar_gzip_out) .`))
            end

            s_tarjl_codec = filesize(tarjl_codec_out)
            s_tarjl_gzip = filesize(tarjl_gzip_out)
            s_tar_gzip = filesize(tar_gzip_out)

            # Convert to time in ms
            ms(t) = minimum(t).time/1e6
            @info(@sprintf("%s: %.1fms to generate", string(genfunc), t_gen*1e3),
                ms(t_create_tarjl),
                ms(t_create_tar),
                s_tarjl,
                s_tar,
                ms(t_list_tarjl),
                ms(t_list_tar),
                "GZIP_COMPRESSION",
                ms(t_create_tarjl_codec),
                ms(t_create_tarjl_gzip),
                ms(t_create_tar_gzip),
                s_tarjl_codec,
                s_tarjl_gzip,
                s_tar_gzip,
            )
        end
    end
end

Random.seed!(0)
time_tar(many_small_files)
time_tar(some_medium_files)
time_tar(few_large_files)

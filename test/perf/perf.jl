using Random, Tar, Printf, BenchmarkTools

function fill_tree!(root::String, depth::Int, max_dirs::Int, max_files::Int, max_size::Int)
    if depth <= 0
        return
    end

    # First, create files
    for file_idx in 1:rand(1:max_files)
        fname = randstring(rand(5:20))
        open(joinpath(root, fname), "w") do io
            write(io, rand(UInt8, rand(1:max_size)))
        end
    end

    # Next, create directories and recurse
    for dir_idx in 1:rand(1:max_dirs)
        dname = joinpath(root, randstring(rand(5:20)))
        mkdir(dname)
        fill_tree!(dname, depth-1, max_dirs, max_files, max_size)
    end
end


function many_small_files(dir, depth=3, max_dirs=3, max_files=100, max_size=1000)
    fill_tree!(dir, depth, max_dirs, max_files, max_size)
end
function some_medium_files(dir, depth=2, max_dirs=3, max_files=5, max_size=1000*1000)
    fill_tree!(dir, depth, max_dirs, max_files, max_size)
end
function few_large_files(dir, depth=1, max_dirs=2, max_files=3, max_size=100*1000*1000)
    fill_tree!(dir, depth, max_dirs, max_files, max_size)
end

function time_tar(genfunc::Function; kwargs...)
    mktempdir() do dir
        t_gen = @elapsed genfunc(dir; kwargs...)
        mktempdir() do outdir
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

            @info(@sprintf("%s: %.1fs to generate", string(genfunc), t_gen),
                minimum(t_create_tarjl),
                minimum(t_create_tar),
                s_tarjl,
                s_tar,
                minimum(t_list_tarjl),
                minimum(t_list_tar),
            )
        end
    end
end

Random.seed!(0)
time_tar(many_small_files)
time_tar(some_medium_files)
time_tar(few_large_files)

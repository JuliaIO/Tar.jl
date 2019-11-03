using Test

import Tar
import Pkg.GitTools: tree_hash

function gen_file(file::String, size::Int)
    open(file, write=true) do io
        for i = 1:size; write(io, i % UInt8); end
    end
end

@testset "create git hash equality" begin
    top = mktempdir()
    let i = 0, paths = String[]
        for a in [0, 10, 154, 155, 156, 255]
            dir = joinpath(top, "d"^a)
            push!(paths, normpath("..", dir))
            a > 0 && mkdir(dir)
            for b in [10, 99, 100, 101, 255]
                for s in [0, 511, 512, 513, 1000]
                    f = rpad("$s-", b, "f")
                    x = rpad("$s-", b, "x")
                    file = joinpath(dir, f)
                    exec = joinpath(dir, x)
                    gen_file(file, s)
                    gen_file(exec, s)
                    chmod(file, 0o644)
                    chmod(exec, 0o755)
                    push!(paths, file)
                    push!(paths, exec)
                end
                dir′ = joinpath(dir, "s"^b)
                mkpath(dir′)
                push!(paths, dir′)
                target = relpath(paths[i += 1], top)
                link = joinpath(dir, "l"^b)
                symlink(target, link)
                push!(paths, link)
                broken = joinpath(dir, "b"^b)
                if target != "."
                    symlink(chop(target), broken)
                    push!(paths, broken)
                end
            end
        end
    end
    tarball = Tar.create(top)
    top′ = mktempdir()
    run(`tar -C $top′ -xf $tarball`)
    @test tree_hash(top) == tree_hash(top′)
    rm(top, force=true, recursive=true)
    rm(top′, force=true, recursive=true)
end

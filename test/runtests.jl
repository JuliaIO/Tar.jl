using Test

import Tar
import Pkg.GitTools: tree_hash

function gen_file(file::String, size::Int)
    open(file, write=true) do io
        for i = 1:size; write(io, i % UInt8); end
    end
end

function make_test_tarball()
    root = mktempdir()
    let i = 0, paths = String[]
        for a in [0, 10, 154, 155, 156, 255]
            dir = joinpath(root, "d"^a)
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
                target = relpath(paths[i += 1], root)
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
    hash = tree_hash(root)
    tarball = Tar.create(root)
    rm(root, force=true, recursive=true)
    return tarball, hash
end

@testset "create & extract tarball of empty tree" begin
    dir = mktempdir()
    tarball = Tar.create(dir)
    rm(dir, force=true, recursive=true)
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, force=true, recursive=true)
    open(tarball, append=true) do io
        write(io, zeros(UInt8, 512))
    end
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, force=true, recursive=true)
end

# TODO: test that each kind of file gets the right path
# e.g. that dir ends with /; file and link don't

@testset "git tree hash equality" begin
    tarball, hash = make_test_tarball()
    @testset "external tar" begin
        root = mktempdir()
        run(`tar -C $root -xf $tarball`)
        @test tree_hash(root) == hash
        rm(root, force=true, recursive=true)
    end
    @testset "Tar.extract" begin
        root = Tar.extract(tarball)
        @test tree_hash(root) == hash
        rm(root, force=true, recursive=true)
    end
    open(tarball, append=true) do io
        write(io, zeros(UInt8, 512))
    end
    @testset "Tar.extract with trailing zeros" begin
        root = Tar.extract(tarball)
        @test tree_hash(root) == hash
        rm(root, force=true, recursive=true)
    end
    rm(tarball, force=true)
end

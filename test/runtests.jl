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
            b_lengths = [10, 99, 100, 101, 255]
            # don't attempt to create file paths > 260 on windows
            @static if Sys.iswindows()
                filter!(b -> b + a < 260, b_lengths)
            end
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

@testset "empty tarball" begin
    dir = mktempdir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    @test Tar.list(tarball) == [Tar.Header(".", :directory, 0o755, 0, "")]
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, recursive=true)
    open(tarball, append=true) do io
        write(io, zeros(UInt8, 512))
    end
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, recursive=true)
end

function check_tree_hash(hash::Vector{UInt8}, root::AbstractString)
    @test tree_hash(root) == hash
    rm(root, recursive=true)
end

@testset "test tarball" begin
    tarball, hash = make_test_tarball()
    @testset "Tar.list & check properties" begin
        headers = Tar.list(tarball)
        @test issorted(headers, by = hdr -> hdr.path)
        for hdr in headers
            @test !isempty(hdr.path)
            @test hdr.type in (:file, :directory, :symlink)
            if hdr.type == :file
                @test hdr.path[end] != '/'
                @test hdr.mode in (0o644, 0o755)
                @test isempty(hdr.link)
            elseif hdr.type == :directory
                @test hdr.path[end] == '/'
                @test hdr.mode == 0o755
                @test hdr.size == 0
                @test isempty(hdr.link)
            elseif hdr.type == :symlink
                @test hdr.path[end] != '/'
                @test hdr.mode == 0o755
                @test hdr.size == 0
                @test !isempty(hdr.link)
            end
        end
        @testset "Tar.list from IO, process, pipeline" begin
            @test headers == open(Tar.list, tarball)
            @test headers == open(Tar.list, `cat $tarball`)
            @test headers == open(Tar.list, pipeline(`bzip2 -c -9 $tarball`, `bzcat`))
        end
    end
    @testset "extract with `tar` command" begin
        root = mktempdir()
        run(`tar -C $root -xf $tarball`)
        check_tree_hash(hash, root)
    end
    @testset "Tar.extract" begin
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
    @testset "Tar.extract from IO, process, pipeline" begin
        root = open(Tar.extract, tarball)
        check_tree_hash(hash, root)
        root = open(Tar.extract, `cat $tarball`)
        check_tree_hash(hash, root)
        root = open(Tar.extract, pipeline(`bzip2 -c -9 $tarball`, `bzcat`))
        check_tree_hash(hash, root)
    end
    open(tarball, append=true) do io
        write(io, zeros(UInt8, 512))
    end
    @testset "Tar.extract with trailing zeros" begin
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
    rm(tarball)
end

@testset "symlink attacks" begin
    # not dangerous but still not allowed
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("dir", :directory, 0o755, 0, ""))
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "dir"))
    Tar.write_header(io, Tar.Header("link/target", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    rm(tarball)
    # attempt to write through relative link out of root
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "../target"))
    Tar.write_header(io, Tar.Header("link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    rm(tarball)
    # attempt to write through absolute link
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    rm(tarball)
    # same attack with some obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("./link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    rm(tarball)
    # same attack with different obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("dir/../link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    rm(tarball)
end

@testset "symlink overwrite" begin
    # allowable and should work
    tarball₁, io = mktemp()
    Tar.write_header(io, Tar.Header("file", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("file", :file, 0o644, 0, ""))
    close(io)
    tree₁ = Tar.extract(tarball₁)
    tarball₂, io = mktemp()
    Tar.write_header(io, Tar.Header("file", :file, 0o644, 0, ""))
    close(io)
    tree₂ = Tar.extract(tarball₂)
    @test tree_hash(tree₁) == tree_hash(tree₂)
    rm(tree₁, recursive=true)
    rm(tree₂, recursive=true)
    rm(tarball₁)
    rm(tarball₂)
end

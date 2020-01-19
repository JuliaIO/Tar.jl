using Test

import Tar
import Pkg.GitTools: tree_hash

function gen_file(file::String, size::Int)
    open(file, write=true) do io
        for i = 1:size; write(io, i % UInt8); end
    end
end

function make_test_tarball(tar_create::Function = Tar.create)
    root = mktempdir()
    let i = 0, paths = String[]
        a_lengths = [0, 10, 154, 155, 156, 255]
        @static if Sys.iswindows()
            filter!(a -> 2 + a + length(root) < 260, a_lengths)
        end
        for a in a_lengths
            dir = joinpath(root, "d"^a)
            push!(paths, normpath("..", dir))
            a > 0 && mkdir(dir)
            b_lengths = [10, 99, 100, 101, 255]
            # don't attempt to create file paths > 260 on windows
            @static if Sys.iswindows()
                filter!(b -> 4 + b + a + length(root) < 260, b_lengths)
            end
            for b in b_lengths
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
                link = joinpath(dir, "l"^b)
                target = relpath(paths[i += 1], link)
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
    tarball = tar_create(root)
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
    # skip `tar` tests when it doesn't exist or when we're on windows
    if Sys.which("tar") != nothing && !Sys.iswindows()
        @testset "extract with `tar` command" begin
            root = mktempdir()
            run(`tar -C $root -xf $tarball`)
            check_tree_hash(hash, root)
        end
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

if Sys.which("gtar") != nothing && !Sys.iswindows()
    @testset "POSIX extensions" begin
        # make a test POSIX tarball with `gtar` instead of Tar.create
        tarball, hash = make_test_tarball() do root
            tarball, io = mktemp(); close(io)
            run(`gtar --format=posix -C $root -cf $tarball .`)
            return tarball
        end
        # TODO: check that extended headers contain `mtime` etc.
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
    @testset "GNU extensions" begin
        # make a test GNU tarball with `gtar` instead of Tar.create
        tarball, hash = make_test_tarball() do root
            tarball, io = mktemp(); close(io)
            run(`gtar --format=gnu -C $root -cf $tarball .`)
            return tarball
        end
        hdrs = Tar.list(tarball, raw=true)
        # test that both long link and long name entries are created
        @test any(h.path == "././@LongLink" && h.type == :L for h in hdrs)
        @test any(h.path == "././@LongLink" && h.type == :K for h in hdrs)
        # test that Tar can extract these GNU entries correctly
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
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

!Sys.iswindows() &&
@testset "symlink overwrite" begin
    # allowable and should work
    @testset "allow overwriting a symlink" begin
        tarball₁, io = mktemp()
        Tar.write_header(io, Tar.Header("path", :symlink, 0o755, 0, "/tmp"))
        Tar.write_header(io, Tar.Header("path", :file, 0o644, 0, ""))
        close(io)
        tree₁ = Tar.extract(tarball₁)
        tarball₂, io = mktemp()
        Tar.write_header(io, Tar.Header("path", :file, 0o644, 0, ""))
        close(io)
        tree₂ = Tar.extract(tarball₂)
        @test tree_hash(tree₁) == tree_hash(tree₂)
        rm(tree₁, recursive=true)
        rm(tree₂, recursive=true)
        rm(tarball₁)
        rm(tarball₂)
    end
    @testset "allow write into directory overwriting a symlink" begin
        # make sure "path" is removed from links set
        tarball₁, io = mktemp()
        Tar.write_header(io, Tar.Header("path", :symlink, 0o755, 0, "/tmp"))
        Tar.write_header(io, Tar.Header("path", :directory, 0o755, 0, ""))
        Tar.write_header(io, Tar.Header("path/file", :file, 0o644, 0, ""))
        close(io)
        tree₁ = Tar.extract(tarball₁)
        tarball₂, io = mktemp()
        Tar.write_header(io, Tar.Header("path/file", :file, 0o644, 0, ""))
        close(io)
        tree₂ = Tar.extract(tarball₂)
        @test tree_hash(tree₁) == tree_hash(tree₂)
        rm(tree₁, recursive=true)
        rm(tree₂, recursive=true)
        rm(tarball₁)
        rm(tarball₂)
    end
end

function make_test_dir(gen_skip::Bool=false)
    dir = mktempdir()
    touch(joinpath(dir, "file"))
    if gen_skip
        touch(joinpath(dir, "file.skip"))
    end
    mkdir(joinpath(dir, "dir"))
    touch(joinpath(dir, "dir", "file"))
    mkdir(joinpath(dir, "empty"))
    if gen_skip
        touch(joinpath(dir, "dir", "file.skip"))
    end
    if gen_skip
        mkdir(joinpath(dir, "dir.skip"))
        touch(joinpath(dir, "dir.skip", "file"))
    end
    if !Sys.iswindows()
        symlink("file", joinpath(dir, "link"))
        if gen_skip
            symlink("file", joinpath(dir, "link.skip"))
        end
    end
    return dir
end

const test_dir_paths = ["dir/file", "empty/", "file", "link"]
Sys.iswindows() && pop!(test_dir_paths)

@testset "API: create" begin
    dir = make_test_dir()
    @test !any(splitext(name)[2] == ".skip" for name in readdir(dir))
    # create(dir::String)
    tarball = Tar.create(dir)
    bytes = read(tarball)
    @test isfile(tarball)
    rm(tarball)
    # create(dir::String, tarball::String)
    tarball = tempname()
    Tar.create(dir, tarball)
    @test read(tarball) == bytes
    rm(tarball)
    # create(dir::String, tarball::IO)
    mktemp() do tarball, io
        Tar.create(dir, tarball)
        close(io)
        @test read(tarball) == bytes
    end
    rm(dir, recursive=true)
    # test predicate versions
    dir = make_test_dir(true)
    @test any(splitext(name)[2] == ".skip" for name in readdir(dir))
    predicate = path -> splitext(path)[2] != ".skip"
    # create(predicate::Function, dir::String)
    tarball = Tar.create(predicate, dir)
    @test read(tarball) == bytes
    rm(tarball)
    # create(predicate::Function, dir::String, tarball::String)
    tarball = tempname()
    Tar.create(predicate, dir, tarball)
    @test read(tarball) == bytes
    rm(tarball)
    # create(predicate::Function, dir::String, tarball::IO)
    mktemp() do tarball, io
        Tar.create(predicate, dir, tarball)
        close(io)
        @test read(tarball) == bytes
    end
    rm(dir, recursive=true)
end

@testset "API: list" begin
    dir = make_test_dir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    # list(tarball::String)
    headers = Tar.list(tarball)
    @test test_dir_paths == [hdr.path for hdr in headers]
    # list(tarball::IO)
    headers = open(Tar.list, tarball)
    @test test_dir_paths == [hdr.path for hdr in headers]
    # add a sketchy entry to tarball
    open(tarball, append=true) do io
        Tar.write_header(io, Tar.Header("/bad", :file, 0o644, 0, ""))
    end
    paths = push!(copy(test_dir_paths), "/bad")
    # list(tarball::String; strict=true|false)
    @test_throws ErrorException Tar.list(tarball)
    @test_throws ErrorException Tar.list(tarball, strict=true)
    headers = Tar.list(tarball, strict=false)
    @test paths == [hdr.path for hdr in headers]
    # list(tarball::IO; strict=true|false)
    @test_throws ErrorException open(Tar.list, tarball)
    @test_throws ErrorException open(tarball) do io
        Tar.list(io, strict=true)
    end
    headers = open(tarball) do io
        Tar.list(io, strict=false)
    end
    @test paths == [hdr.path for hdr in headers]
end

@testset "API: extract" begin
    dir = make_test_dir()
    hash = tree_hash(dir)
    tarball = Tar.create(dir)
    rm(dir, recursive=true)

    # extract(tarball::String)
    dir = Tar.extract(tarball)
    check_tree_hash(hash, dir)
    # extract(tarball::String, dir::String) — non-existent
    dir = tempname()
    Tar.extract(tarball, dir)
    check_tree_hash(hash, dir)
    # extract(tarball::String, dir::String) — existent, empty
    dir = mktempdir()
    Tar.extract(tarball, dir)
    check_tree_hash(hash, dir)
    # extract(tarball::String, dir::String) — non-directory (error)
    dir = tempname()
    touch(dir)
    @test_throws ErrorException Tar.extract(tarball, dir)
    rm(dir)
    # extract(tarball::String, dir::String) — non-empty directory (error)
    dir = mktempdir()
    touch(joinpath(dir, "file"))
    @test_throws ErrorException Tar.extract(tarball, dir)
    rm(dir, recursive=true)

    # extract(tarball::IO)
    dir = open(Tar.extract, tarball)
    check_tree_hash(hash, dir)
    # extract(tarball::IO, dir::String) — non-existent
    dir = tempname()
    open(tarball) do io
        Tar.extract(io, dir)
    end
    check_tree_hash(hash, dir)
    # extract(tarball::IO, dir::String) — existent, empty
    dir = mktempdir()
    open(tarball) do io
        Tar.extract(io, dir)
    end
    check_tree_hash(hash, dir)
    # extract(tarball::IO, dir::String) — non-directory (error)
    dir = tempname()
    touch(dir)
    @test_throws ErrorException open(tarball) do io
        Tar.extract(io, dir)
    end
    rm(dir)
    # extract(tarball::IO, dir::String) — non-empty directory (error)
    dir = mktempdir()
    touch(joinpath(dir, "file"))
    @test_throws ErrorException open(tarball) do io
        Tar.extract(io, dir)
    end
    rm(dir, recursive=true)
end

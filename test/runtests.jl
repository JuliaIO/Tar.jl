include("setup.jl")

@testset "empty tarball" begin
    dir = mktempdir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    @test Tar.list(tarball) == [Tar.Header(".", :directory, 0o755, 0, "")]
    test_empty_hashes(tarball)
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, recursive=true)
    open(tarball, append=true) do io
        write(io, zeros(UInt8, 512))
    end
    test_empty_hashes(tarball)
    dir = Tar.extract(tarball)
    @test isempty(readdir(dir))
    rm(dir, recursive=true)
end

@testset "test tarball" begin
    tarball, hash = make_test_tarball()
    @testset "Tar.tree_hash" begin
        @test Tar.tree_hash(tarball, skip_empty=true) == hash
        open(tarball) do io
            @test Tar.tree_hash(io, skip_empty=true) == hash
        end
        @test empty_tree_sha1 == Tar.tree_hash(hdr->false, tarball)
        @test empty_tree_sha1 ==
            Tar.tree_hash(hdr->false, tarball, algorithm="git-sha1")
        @test empty_tree_sha256 ==
            Tar.tree_hash(hdr->false, tarball, algorithm="git-sha256")
        open(tarball) do io
            @test empty_tree_sha1 == Tar.tree_hash(hdr->false, tarball)
        end
        open(tarball) do io
            @test empty_tree_sha1 ==
                Tar.tree_hash(hdr->false, tarball, algorithm="git-sha1")
        end
        open(tarball) do io
            @test empty_tree_sha256 ==
                Tar.tree_hash(hdr->false, tarball, algorithm="git-sha256")
        end
    end
    @testset "Tar.list & check properties" begin
        headers = Tar.list(tarball)
        @test issorted(headers, by = hdr -> hdr.path)
        for hdr in headers
            @test !isempty(hdr.path)
            @test hdr.path[end] != '/'
            @test hdr.type in (:file, :directory, :symlink)
            if hdr.type == :file
                @test hdr.mode in (0o644, 0o755)
                @test isempty(hdr.link)
            elseif hdr.type == :directory
                @test hdr.mode == 0o755
                @test hdr.size == 0
                @test isempty(hdr.link)
            elseif hdr.type == :symlink
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

if !Sys.iswindows()
    @testset "POSIX extended headers" begin
        # make a test POSIX tarball with GNU `tar` from Tar_jll instead of Tar.create
        tarball, hash = make_test_tarball() do root
            tarball, io = mktemp()
            Tar.write_extended_header(io, type = :g, ["comment" => "Julia Rocks!"])
            close(io)
            tar(gtar -> run(`$gtar --format=posix -C $root --append -f $tarball .`))
            return tarball
        end
        # TODO: check that extended headers contain `mtime` etc.
        @test Tar.tree_hash(tarball, skip_empty=true) == hash
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
    @testset "GNU extensions" begin
        # make a test GNU tarball with GNU `tar` from Tar_jll instead of Tar.create
        tarball, hash = make_test_tarball() do root
            tarball = tempname()
            tar(gtar -> run(`$gtar --format=gnu -C $root -cf $tarball .`))
            return tarball
        end
        hdrs = Tar.list(tarball, raw=true)
        # test that both long link and long name entries are created
        @test any(h.path == "././@LongLink" && h.type == :L for h in hdrs)
        @test any(h.path == "././@LongLink" && h.type == :K for h in hdrs)
        # test that Tar can extract these GNU entries correctly
        @test Tar.tree_hash(tarball, skip_empty=true) == hash
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
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # attempt to write through relative link out of root
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "../target"))
    Tar.write_header(io, Tar.Header("link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # attempt to write through absolute link
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # same attack with some obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("./link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # same attack with different obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, "/tmp"))
    Tar.write_header(io, Tar.Header("dir/../link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
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
        hash = Tar.tree_hash(tarball₁)
        tree₁ = Tar.extract(tarball₁)
        @test hash == tree_hash(tree₁)
        tarball₂, io = mktemp()
        Tar.write_header(io, Tar.Header("path", :file, 0o644, 0, ""))
        close(io)
        @test hash == Tar.tree_hash(tarball₂)
        tree₂ = Tar.extract(tarball₂)
        @test hash == tree_hash(tree₂)
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
        hash = Tar.tree_hash(tarball₁)
        tree₁ = Tar.extract(tarball₁)
        @test hash == tree_hash(tree₁)
        tarball₂, io = mktemp()
        Tar.write_header(io, Tar.Header("path/file", :file, 0o644, 0, ""))
        close(io)
        @test hash == Tar.tree_hash(tarball₂)
        tree₂ = Tar.extract(tarball₂)
        @test hash == tree_hash(tree₂)
        rm(tree₁, recursive=true)
        rm(tree₂, recursive=true)
        rm(tarball₁)
        rm(tarball₂)
    end
end

@testset "API: create" begin
    local bytes

    @testset "without predicate" begin
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
            Tar.create(dir, io)
            @test read(tarball) == bytes
        end
        rm(dir, recursive=true)
    end

    @testset "with predicate" begin
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
            Tar.create(predicate, dir, io)
            @test read(tarball) == bytes
        end
        rm(dir, recursive=true)
    end
end

@testset "API: list" begin
    dir = make_test_dir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    n = length(test_dir_paths)

    # list(tarball::String)
    headers = Tar.list(tarball)
    @test test_dir_paths == [hdr.path for hdr in headers]
    @test n == tar_count(tarball)
    # list(tarball::IO)
    headers = open(Tar.list, tarball)
    @test test_dir_paths == [hdr.path for hdr in headers]
    @test n == open(tar_count, tarball)
    # add a sketchy entry to tarball
    open(tarball, append=true) do io
        Tar.write_header(io, Tar.Header("/bad", :file, 0o644, 0, ""))
    end
    paths = push!(copy(test_dir_paths), "/bad")
    # list(tarball::String; strict=true|false)
    @test_throws ErrorException Tar.list(tarball)
    @test_throws ErrorException Tar.list(tarball, strict=true)
    @test_throws ErrorException tar_count(tarball)
    @test_throws ErrorException tar_count(tarball, strict=true)
    headers = Tar.list(tarball, strict=false)
    @test paths == [hdr.path for hdr in headers]
    @test n + 1 == tar_count(tarball, strict=false)
    # list(tarball::IO; strict=true|false)
    @test_throws ErrorException open(Tar.list, tarball)
    @test_throws ErrorException open(tarball) do io
        Tar.list(io, strict=true)
    end
    @test_throws ErrorException open(tar_count, tarball)
    @test_throws ErrorException open(tarball) do io
        tar_count(io, strict=true)
    end
    headers = open(tarball) do io
        Tar.list(io, strict=false)
    end
    @test paths == [hdr.path for hdr in headers]
    @test n + 1 == open(tarball) do io
        tar_count(io, strict=false)
    end
end

@testset "API: extract" begin
    dir = make_test_dir()
    hash = tree_hash(dir)
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    @test hash == Tar.tree_hash(tarball, skip_empty=true)
    @test hash != Tar.tree_hash(tarball, skip_empty=false)

    @testset "without predicate" begin
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

    @testset "with predicate" begin
        # generate a version of dir with .skip entries
        dir = make_test_dir(true)
        tarball = Tar.create(dir)
        rm(dir, recursive=true)
        @test hash != Tar.tree_hash(tarball, skip_empty=true)
        @test hash != Tar.tree_hash(tarball, skip_empty=false)

        # predicate to skip paths ending in `.skip`
        predicate = hdr -> !any(splitext(p)[2] == ".skip" for p in split(hdr.path, '/'))
        @test hash == Tar.tree_hash(predicate, tarball, skip_empty=true)
        @test hash != Tar.tree_hash(predicate, tarball, skip_empty=false)

        # extract(predicate::Function, tarball::String)
        dir = Tar.extract(predicate, tarball)
        check_tree_hash(hash, dir)
        # extract(predicate::Function, tarball::String, dir::String)
        dir = tempname()
        Tar.extract(predicate, tarball, dir)
        check_tree_hash(hash, dir)
        # extract(predicate::Function, tarball::IO)
        dir = open(tarball) do io
            Tar.extract(predicate, io)
        end
        check_tree_hash(hash, dir)
        # extract(tarball::IO, dir::String) — non-existent
        dir = tempname()
        open(tarball) do io
            Tar.extract(predicate, io, dir)
        end
        check_tree_hash(hash, dir)
    end
end

@testset "API: rewrite" begin
    # reference standard tarball
    reference, hash₁ = make_test_tarball()
    ref = read(reference)

    # alternate format tarball
    if !Sys.iswindows()
        # alternate tarball made by GNU tar
        alternate, hash₂ = make_test_tarball() do root
            tarball = tempname()
            tar(gtar -> run(`$gtar -C $root -cf $tarball .`))
            return tarball
        end
        @test hash₁ == hash₂
        @test ref != read(alternate)
    else
        # at least test the plumbing
        alternate = tempname()
        cp(reference, alternate)
    end

    @testset "without predicate" begin
        # rewrite(old::String)
        tarball = Tar.rewrite(alternate)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(old::String, new::String)
        tarball = tempname()
        Tar.rewrite(alternate, tarball)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(old::IO)
        tarball = open(Tar.rewrite, alternate)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(old::Process)
        tarball = open(Tar.rewrite, `cat $alternate`)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(old::IO, new::String)
        tarball = tempname()
        open(alternate) do io
            Tar.rewrite(io, tarball)
        end
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(old::String, new::IO)
        tarball = tempname()
        open(tarball, write=true) do io
            Tar.rewrite(alternate, io)
            @test ref == read(tarball)
        end
        rm(tarball)
        # rewrite(old::IO, new::IO)
        tarball = tempname()
        open(alternate) do old
            open(tarball, write=true) do new
                Tar.rewrite(old, new)
            end
            @test ref == read(tarball)
        end
        rm(tarball)
    end

    @testset "with predicate" begin
        predicate = hdr ->
            hdr.type == :symlink ? isodd(length(hdr.link)) : isodd(hdr.size)
        filtered = Tar.create(Tar.extract(predicate, reference))
        ref = read(filtered)
        rm(filtered)

        # rewrite(predicate::Function, old::String) — reference
        tarball = Tar.rewrite(predicate, reference)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(predicate::Function, old::String) — alternate
        tarball = Tar.rewrite(predicate, alternate)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(predicate::Function, old::String, new::String)
        tarball = tempname()
        Tar.rewrite(predicate, alternate, tarball)
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(predicate::Function, old::IO)
        tarball = open(alternate) do io
            Tar.rewrite(predicate, io)
        end
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(predicate::Function, old::IO, new::String)
        tarball = tempname()
        open(alternate) do io
            Tar.rewrite(predicate, io, tarball)
        end
        @test ref == read(tarball)
        rm(tarball)
        # rewrite(predicate::Functoin, old::String, new::IO)
        tarball = tempname()
        open(tarball, write=true) do io
            Tar.rewrite(predicate, alternate, io)
            @test ref == read(tarball)
        end
        rm(tarball)
        # rewrite(predicate::Function, old::IO, new::IO)
        tarball = tempname()
        open(alternate) do old
            open(tarball, write=true) do new
                Tar.rewrite(predicate, old, new)
            end
            @test ref == read(tarball)
        end
        rm(tarball)
    end

    # cleanup
    rm(alternate)
    rm(reference)
end

@testset "API: skeletons" begin
    # make some tarballs to test with
    tarballs = String[]
    let dir = make_test_dir()
        push!(tarballs, Tar.create(dir))
        rm(dir, recursive=true)
    end
    push!(tarballs, make_test_tarball()[1])
    Sys.iswindows() || push!(tarballs, make_test_tarball() do root
        tarball = tempname()
        tar(gtar -> run(`$gtar --format=gnu -C $root -cf $tarball .`))
        return tarball
    end[1])
    for i = 1:length(tarballs)
        tarball = tempname()
        cp(tarballs[1], tarball)
        open(tarball, append=true) do io
            write(io, zeros(UInt8, 1024))
        end
        push!(tarballs, tarball)
    end

    for tarball in tarballs
        reference = read(tarball)
        # check that tarballs are recreated exactly
        skeleton = tempname()
        @test !ispath(skeleton)
        dir = Tar.extract(tarball, skeleton=skeleton)
        @test Tar.list(tarball) == Tar.list(skeleton)
        @test isfile(skeleton)
        tarball′ = Tar.create(dir, skeleton=skeleton)
        @test reference == read(tarball′)
        rm(tarball′)
        # check that passing an IO handle to create works
        open(skeleton) do io
            tarball′ = Tar.create(dir, skeleton=io)
            @test reference == read(tarball′)
            rm(tarball′)
        end
        # check that extracting skeleton IO is the same
        mktemp() do skeleton′, io
            Tar.extract(tarball, skeleton=io)
            @test read(skeleton) == read(skeleton′)
        end
        rm(skeleton)
    end

    # cleanup
    foreach(rm, tarballs)
end

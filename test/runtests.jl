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
        arg_readers(tarball) do tar
            @arg_test tar @test Tar.tree_hash(tar, skip_empty=true) == hash
            @arg_test tar @test empty_tree_sha1 == Tar.tree_hash(hdr->false, tar)
            @arg_test tar @test empty_tree_sha1 ==
                Tar.tree_hash(hdr->false, tar, algorithm="git-sha1")
            @arg_test tar @test empty_tree_sha256 ==
                Tar.tree_hash(hdr->false, tar, algorithm="git-sha256")
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
            arg_readers(tarball) do tar
                @arg_test tar begin
                    @test headers == Tar.list(tar)
                end
            end
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
        arg_readers(tarball) do tar
            @arg_test tar begin
                root = Tar.extract(tar)
                check_tree_hash(hash, root)
            end
        end
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
            gtar(gtar -> run(`$gtar --format=posix -C $root --append -f $tarball .`))
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
            gtar(gtar -> run(`$gtar --format=gnu -C $root -cf $tarball .`))
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

        # create(dir)
        tarball = Tar.create(dir)
        bytes = read(tarball)
        @test isfile(tarball)
        rm(tarball)

        # create(dir, tarball)
        arg_writers() do tarball, tar
            @arg_test tar begin
                @test tar == Tar.create(dir, tar)
            end
            @test read(tarball) == bytes
        end

        # cleanup
        rm(dir, recursive=true)
    end

    @testset "with predicate" begin
        dir = make_test_dir(true)
        @test any(splitext(name)[2] == ".skip" for name in readdir(dir))
        predicate = path -> splitext(path)[2] != ".skip"

        # create(predicate, dir)
        tarball = Tar.create(predicate, dir)
        @test read(tarball) == bytes
        rm(tarball)

        # create(predicate, dir, tarball)
        arg_writers() do tarball, tar
            @arg_test tar begin
                @test tar == Tar.create(predicate, dir, tar)
            end
            @test read(tarball) == bytes
        end

        # cleanup
        rm(dir, recursive=true)
    end
end

@testset "API: list" begin
    dir = make_test_dir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    n = length(test_dir_paths)

    # list([predicate,] tarball)
    arg_readers(tarball) do tar
        @arg_test tar begin
            headers = Tar.list(tar)
            @test test_dir_paths == [hdr.path for hdr in headers]
        end
        @arg_test tar @test n == tar_count(tar)
    end

    # add a sketchy entry to tarball
    open(tarball, append=true) do io
        Tar.write_header(io, Tar.Header("/bad", :file, 0o644, 0, ""))
    end
    paths = push!(copy(test_dir_paths), "/bad")

    # list([predicate,] tarball; strict=true|false)
    arg_readers(tarball) do tar
        @arg_test tar @test_throws ErrorException Tar.list(tar)
        @arg_test tar @test_throws ErrorException Tar.list(tar, strict=true)
        @arg_test tar begin
            headers = Tar.list(tar, strict=false)
            @test paths == [hdr.path for hdr in headers]
        end
        @arg_test tar @test_throws ErrorException tar_count(tar)
        @arg_test tar @test_throws ErrorException tar_count(tar, strict=true)
        @arg_test tar @test n + 1 == tar_count(tar, strict=false)
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
        arg_readers(tarball) do tar
            # extract(tarball)
            @arg_test tar begin
                dir = Tar.extract(tar)
                check_tree_hash(hash, dir)
            end
            # extract(tarball, dir) — non-existent
            @arg_test tar begin
                dir = tempname()
                Tar.extract(tar, dir)
                check_tree_hash(hash, dir)
            end
            # extract(tarball, dir) — existent, empty
            @arg_test tar begin
                dir = mktempdir()
                Tar.extract(tar, dir)
                check_tree_hash(hash, dir)
            end
            # extract(tarball, dir) — non-directory (error)
            @arg_test tar begin
                file = tempname()
                touch(file)
                @test_throws ErrorException Tar.extract(tar, file)
                rm(file)
            end
            # extract(tarball, dir) — non-empty directory (error)
            @arg_test tar begin
                dir = mktempdir()
                touch(joinpath(dir, "file"))
                @test_throws ErrorException Tar.extract(tar, dir)
                rm(dir, recursive=true)
            end
        end
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

        arg_readers(tarball) do tar
            # extract(predicate, tarball)
            @arg_test tar begin
                dir = Tar.extract(predicate, tar)
                check_tree_hash(hash, dir)
            end
            # extract(predicate, tarball, dir) — non-existent
            @arg_test tar begin
                dir = tempname()
                Tar.extract(predicate, tar, dir)
                check_tree_hash(hash, dir)
            end
            # extract(predicate, tarball, dir) — existent, empty
            @arg_test tar begin
                dir = mktempdir()
                Tar.extract(predicate, tar, dir)
                check_tree_hash(hash, dir)
            end
            # extract(predicate, tarball, dir) — non-directory (error)
            @arg_test tar begin
                file = tempname()
                touch(file)
                @test_throws ErrorException Tar.extract(predicate, tar, file)
                rm(file)
            end
            # extract(predicate, tarball, dir) — non-empty directory (error)
            @arg_test tar begin
                dir = mktempdir()
                touch(joinpath(dir, "file"))
                @test_throws ErrorException Tar.extract(predicate, tar, dir)
                rm(dir, recursive=true)
            end
        end
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
            gtar(gtar -> run(`$gtar -C $root -cf $tarball .`))
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
        for tarball in (reference, alternate)
            arg_readers(tarball) do old
                # rewrite(old)
                @arg_test old begin
                    new_file = Tar.rewrite(old)
                    @test ref == read(new_file)
                    rm(new_file)
                end
                # rewrite(old, new)
                arg_writers() do new_file, new
                    @arg_test old new begin
                        @test new == Tar.rewrite(old, new)
                    end
                    @test ref == read(new_file)
                end
            end
        end
    end

    @testset "with predicate" begin
        # made up order-independent tarball predicate
        predicate = hdr ->
            hdr.type == :symlink ? isodd(length(hdr.link)) : isodd(hdr.size)
        filtered = Tar.create(Tar.extract(predicate, reference))
        ref = read(filtered)
        rm(filtered)

        for tarball in (reference, alternate)
            arg_readers(tarball) do old
                # rewrite(predicate, old)
                @arg_test old begin
                    new_file = Tar.rewrite(predicate, old)
                    @test ref == read(new_file)
                    rm(new_file)
                end
                # rewrite(predicate, old, new)
                arg_writers() do new_file, new
                    @arg_test old new begin
                        @test new == Tar.rewrite(predicate, old, new)
                    end
                    @test ref == read(new_file)
                end
            end
        end
    end

    # cleanup
    rm(alternate)
    rm(reference)
end

@testset "API: skeletons" begin
    # make some tarballs to test with
    tarballs = Dict{String,Bool}() # value indicates if we generated
    let dir = make_test_dir()
        tarballs[Tar.create(dir)] = true
        rm(dir, recursive=true)
    end
    tarballs[make_test_tarball()[1]] = true
    if !Sys.iswindows()
        tarball, _ = make_test_tarball() do root
            tarball = tempname()
            gtar(gtar -> run(`$gtar --format=gnu -C $root -cf $tarball .`))
            return tarball
        end
        tarballs[tarball] = false # not generated by Tar.jl
    end
    for (tarball, flag) in collect(tarballs)
        tarball′ = tempname()
        cp(tarball, tarball′)
        open(tarball′, append=true) do io
            write(io, zeros(UInt8, 1024))
            write(io, rand(UInt8, 666))
        end
        tarballs[tarball′] = flag
    end

    for (tarball, flag) in tarballs
        reference = read(tarball)
        # first, generate a skeleton
        skeleton = tempname()
        dir = Tar.extract(tarball, skeleton=skeleton)
        @test isfile(skeleton)
        # test skeleton listing
        hdrs = Tar.list(tarball)
        arg_readers(skeleton) do skel
            @arg_test skel @test hdrs == Tar.list(skel)
        end
        if flag && !Sys.iswindows()
            # GNU tar can list skeleton files of tarballs we generated
            paths = sort!([hdr.path for hdr in hdrs])
            @test paths == sort!(gtar(gtar -> readlines(`$gtar -tf $skeleton`)))
        end
        hdrs = Tar.list(tarball, raw=true)
        arg_readers(skeleton) do skel
            @arg_test skel @test hdrs == Tar.list(skel, raw=true)
            # test reconstruction from skeleton
            @arg_test skel begin
                tarball′ = Tar.create(dir, skeleton=skel)
                @test reference == read(tarball′)
                rm(tarball′)
            end
        end
        # check that extracting skeleton to IO works
        arg_writers() do skeleton′, skel
            @arg_test skel Tar.extract(tarball, skeleton=skel)
            @test read(skeleton) == read(skeleton′)
        end
        rm(skeleton)
    end

    # cleanup
    foreach(rm, keys(tarballs))
end

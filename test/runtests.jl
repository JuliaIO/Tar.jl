include("setup.jl")

NON_STDLIB_TESTS &&
@testset "ChaosBufferStream" begin
    @testset "constant usage" begin
        io = BufferStream()
        cio = ChaosBufferStream(io; chunksizes=[17], sleepamnts=[0.001])
        write(io, rand(UInt8, 30))
        close(io)

        # Test that data comes out in 17-byte chunks (except for the last)
        buff = Array{UInt8}(undef, 30)
        t = @elapsed begin
            @test readbytes!(cio, buff, 30) == 17
            @test readbytes!(cio, buff, 30) == 13
        end
        @test t >= 0.001
    end

    @testset "random usage" begin
        io = BufferStream()
        chunksizes = 5:10
        cio = ChaosBufferStream(io; chunksizes=chunksizes, sleepamnts=[0.0])
        write(io, rand(UInt8, 3000))
        close(io)

        buff = Array{UInt8}(undef, 10)
        while !eof(cio)
            r = readbytes!(cio, buff, 10)
            # In normal operation, the chunk size must be one of
            # the given chunksizes, but at the end of the stream
            # it is allowed to be less.
            if !eof(cio)
                @test r ∈ chunksizes
            else
                @test r <= maximum(chunksizes)
            end
        end
    end
end

@testset "empty tarball" begin
    @testset "empty file as tarball" begin
        tarball = devnull
        @test Tar.list(tarball) == Tar.Header[]
        skel = tempname()
        dir = Tar.extract(tarball, skeleton=skel)
        @test isempty(readdir(dir))
        rm(dir, recursive=true)
        @test isfile(skel)
        @test Tar.list(skel) == Tar.Header[]
        @test Tar.list(skel, raw=true) == Tar.Header[]
        rm(skel)
    end

    @testset "create an empty tarball" begin
        dir = mktempdir()
        tarball = Tar.create(dir)
        rm(dir, recursive=true)
        @test Tar.list(tarball) == [Tar.Header(".", :directory, 0o755, 0, "")]
        @test Tar.list(tarball, raw=true) == [Tar.Header(".", :directory, 0o755, 0, "")]
        test_empty_hashes(tarball)
        skel = tempname()
        dir = Tar.extract(tarball, skeleton=skel)
        @test isempty(readdir(dir))
        rm(dir, recursive=true)
        @test isfile(skel)
        @test Tar.list(skel) == [Tar.Header(".", :directory, 0o755, 0, "")]
        @test Tar.list(skel, raw=true) == [Tar.Header(".", :directory, 0o755, 0, "")]
        rm(skel)
        open(tarball, append=true) do io
            write(io, zeros(UInt8, 512))
        end
        test_empty_hashes(tarball)
        dir = Tar.extract(tarball)
        @test isempty(readdir(dir))
        rm(dir, recursive=true)
    end
end

@testset "test tarball" begin
    tarball, hash = make_test_tarball()
    @testset "Tar.tree_hash" begin
        arg_readers(tarball) do tar
            @arg_test tar @test Tar.tree_hash(tar) == hash
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
    if @isdefined(gtar)
        @testset "extract with `tar` command" begin
            root = mktempdir()
            gtar(gtar -> run(`$gtar -C $root -xf $tarball`))
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

@testset "large files" begin
    # don't generate enormous tarballs, just test header read/write
    for (size, enc) in [
            0                   => "00000000000 "
            123456789           => "00726746425 "
            9924559547          => "111743141273"
            68719476735         => "777777777777"
            68719476736         => "\x80\0\0\0\x00\x00\x00\x10\x00\x00\x00\x00"
            7657359156661993681 => "\x80\0\0\0\x6a\x44\x67\x95\x22\x6c\x40\xd1"
            9223372036854775807 => "\x80\0\0\0\x7f\xff\xff\xff\xff\xff\xff\xff"
        ]
        hdr = Tar.Header("file", :file, 0o644, size, "")
        @testset "standard header" begin
            buf = sprint(io -> Tar.write_standard_header(io, hdr))
            @test ncodeunits(buf) == 512
            dump = Dict(Tar.dump_header(codeunits(buf)))
            @test dump[:size] == enc
            hdr′ = Tar.read_standard_header(IOBuffer(buf))
            @test hdr == hdr′
        end
        @testset "extended header" begin
            buf = sprint(io -> Tar.write_header(io, hdr))
            if hdr.size < 68719476736 # small file size == 8^12
                @test ncodeunits(buf) == 512
            else
                @test ncodeunits(buf) == 3*512
                io = IOBuffer(buf)
                # check extended header
                xhdr = Tar.read_standard_header(io)
                @test xhdr.type == :x
                # check extended data block
                line = readline(io)
                @test line == "$(xhdr.size) size=$(size)"
                data = read!(io, fill(0xff, 512-ncodeunits(line)-1))
                @test length(data) == 512-ncodeunits(line)-1
                @test all(iszero, data)
                # check standard header
                hdr′ = Tar.read_standard_header(io)
                @test hdr == hdr′
                @test eof(io)
            end
        end
    end
end

@testset "truncated tarballs" begin
    # make a simple tarball
    len = 1234
    pad = mod(-len, 512)
    data = rand(UInt8, len)
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("file", :file, 0o644, len, ""))
    write(io, data)
    write(io, fill(0x0, pad))
    close(io)

    @testset "tarball is well-formed" begin
        @test Tar.list(tarball) == [Tar.Header("file", :file, 0o644, len, "")]
        tmp = Tar.extract(tarball)
        @test readdir(tmp) == ["file"]
        @test read(joinpath(tmp, "file")) == data
        rm(tmp, recursive=true)
        tarball′ = Tar.rewrite(tarball)
        @test read(tarball) == read(tarball′)
        rm(tarball′)
    end

    @testset "trailing padding truncated" begin
        for p in [pad-1, pad÷2, 1, 0]
            open(tarball, "a") do io
                truncate(io, 512 + len + p)
            end
            @test_throws_broken EOFError Tar.list(tarball)
            @test_throws EOFError Tar.extract(tarball)
            @test_throws EOFError Tar.tree_hash(tarball)
            @test_throws_broken EOFError Tar.rewrite(tarball)
        end
    end

    @testset "file data truncated" begin
        for d in [len÷2, 512, 0]
            open(tarball, "a") do io
                truncate(io, 512 + d)
            end
            @test_throws_broken EOFError Tar.list(tarball)
            @test_throws EOFError Tar.extract(tarball)
            @test_throws EOFError Tar.tree_hash(tarball)
            @test_throws EOFError Tar.rewrite(tarball)
        end
    end

    @testset "header truncated" begin
        for h in [511, 256, 1]
            open(tarball, "a") do io
                truncate(io, h)
            end
            @test_throws EOFError Tar.list(tarball)
            @test_throws EOFError Tar.extract(tarball)
            @test_throws EOFError Tar.tree_hash(tarball)
            @test_throws EOFError Tar.rewrite(tarball)
        end
    end

    # cleanup
    rm(tarball)
end

if @isdefined(gtar)
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
        @test Tar.tree_hash(tarball) == hash
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
        @test Tar.tree_hash(tarball) == hash
        root = Tar.extract(tarball)
        check_tree_hash(hash, root)
    end
end

@testset "directory after contents" begin
    # create and hash a reference tarball
    tarball, io = mktemp()
    # executable files: hashing works on Windows + old Julia version
    Tar.write_header(io, Tar.Header("dir/file", :file, 0o755, 0, ""))
    Tar.write_header(io, Tar.Header("file", :file, 0o755, 0, ""))
    close(io)
    hash = Tar.tree_hash(tarball)
    rm(tarball)
    # create a version with directory entries after contents
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("file", :file, 0o755, 0, ""))
    Tar.write_header(io, Tar.Header(".", :directory, 0o755, 0, ""))
    Tar.write_header(io, Tar.Header("dir/file", :file, 0o755, 0, ""))
    Tar.write_header(io, Tar.Header("dir", :directory, 0o755, 0, ""))
    close(io)
    # check extract
    tree = Tar.extract(tarball)
    check_tree_hash(hash, tree)
    # check tree_hash
    @test Tar.tree_hash(tarball) == hash
    # check rewrite
    tarball′ = Tar.rewrite(tarball)
    @test Tar.list(tarball′) == [
        Tar.Header("dir", :directory, 0o755, 0, "")
        Tar.Header("dir/file", :file, 0o755, 0, "")
        Tar.Header("file", :file, 0o755, 0, "")
    ]
    # cleanup
    rm(tarball′)
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
    tmp = mktempdir()
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, tmp))
    Tar.write_header(io, Tar.Header("link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # same attack with some obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, tmp))
    Tar.write_header(io, Tar.Header("./link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # same attack with different obfuscation
    tarball, io = mktemp()
    Tar.write_header(io, Tar.Header("link", :symlink, 0o755, 0, tmp))
    Tar.write_header(io, Tar.Header("dir/../link/attack", :file, 0o644, 0, ""))
    close(io)
    @test_throws ErrorException Tar.extract(tarball)
    @test_throws ErrorException Tar.tree_hash(tarball)
    rm(tarball)
    # check temp dir is empty, remove it
    @test isempty(readdir(tmp))
    rm(tmp)
end

!Sys.iswindows() &&
@testset "symlink overwrite" begin
    tmp = mktempdir()
    @testset "allow overwriting a symlink" begin
        tarball₁, io = mktemp()
        Tar.write_header(io, Tar.Header("path", :symlink, 0o755, 0, tmp))
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
        Tar.write_header(io, Tar.Header("path", :symlink, 0o755, 0, tmp))
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
    # check temp dir is empty, remove it
    @test isempty(readdir(tmp))
    rm(tmp)
end

@testset "copy symlinks" begin
    tmp = mktempdir()
    data₁ = randstring(12)
    data₂ = randstring(12)
    tarball, io = mktemp()
    tar_write_file(io, "file", data₁)
    tar_write_link(io, "link-file", "file")
    tar_write_link(io, "link-file-slash", "file/")
    tar_write_link(io, "link-file-slash-dot", "file/.")
    tar_write_link(io, "link-dot-slash-file", "./file")
    tar_write_link(io, "link-dir-dot-dot-file", "dir/../file")
    tar_write_link(io, "link-non-dot-dot-file", "non/../file")
    tar_write_link(io, "link-dir-non-dot-dot-dot-dot-file", "dir/non/../../file")
    tar_write_link(io, "link-self", "link-self")
    tar_write_link(io, "link-cycle-A", "link-cycle-B")
    tar_write_link(io, "link-cycle-B", "link-cycle-A")
    tar_write_link(io, "link-cycle-C", "link-cycle-B")
    tar_write_dir(io,  "dir")
    tar_write_link(io, "link-tmp", tmp)
    tar_write_link(io, "link-dot-dot", "..")
    tar_write_link(io, "link-dot", ".")
    tar_write_link(io, "link-dir", "dir")
    tar_write_link(io, "link-dir-slash", "dir/")
    tar_write_link(io, "link-dir-slash-dot", "dir/.")
    tar_write_link(io, "link-dot-slash-dir", "./dir")
    tar_write_link(io, "link-dot-slash-dir-slash", "./dir/")
    tar_write_link(io, "link-dot-slash-dir-slash-dot", "./dir/.")
    tar_write_link(io, "dir/link-file", "file")
    tar_write_link(io, "dir/link-dot-dot-dir-file", "../dir/file")
    tar_write_link(io, "dir/link-dot-dot-link-dir-file", "../link-dir/file")
    tar_write_link(io, "dir/link-dot-dot-file", "../file")
    tar_write_link(io, "dir/link-dot", ".")
    tar_write_link(io, "dir/link-dot-dot", "..")
    tar_write_link(io, "dir/link-dot-dot-dir", "../dir")
    tar_write_link(io, "dir/link-dot-dot-dir-self", "../dir/link-self")
    tar_write_file(io, "dir/file", data₂)
    close(io)
    # some test utilities (capturing `dir` defined below)
    test_none(path::String) = @test !ispath(joinpath(dir, path))
    test_dir(path::String) = @test isdir(joinpath(dir, path))
    function test_dir(a::String, b::String)
        A = joinpath(dir, a)
        B = joinpath(dir, b)
        @test isdir(A)
        @test isdir(B)
        @test read(Tar.create(A)) == read(Tar.create(B))
    end
    function test_file(path::String, data::String)
        path = joinpath(dir, path)
        @test isfile(path)
        @test read(path, String) == data
    end
    dir = Tar.extract(tarball, copy_symlinks=true)
    test_file("file", data₁)
    test_file("link-file", data₁)
    test_none("link-file-slash")
    test_none("link-file-slash-dot")
    test_file("link-dot-slash-file", data₁)
    test_file("link-dir-dot-dot-file", data₁)
    test_none("link-non-dot-dot-file")
    test_none("link-dir-non-dot-dot-dot-dot-file")
    test_none("link-cycle-A")
    test_none("link-cycle-B")
    test_none("link-cycle-C")
    test_dir("dir")
    test_none("link-tmp")
    test_none("link-dot-dot")
    test_none("link-dot")
    test_dir("link-dir", "dir")
    test_dir("link-dir-slash", "dir")
    test_dir("link-dir-slash-dot", "dir")
    test_dir("link-dot-slash-dir", "dir")
    test_dir("link-dot-slash-dir-slash", "dir")
    test_dir("link-dot-slash-dir-slash-dot", "dir")
    test_file("dir/link-file", data₂)
    test_file("dir/link-dot-dot-dir-file", data₂)
    test_file("dir/link-dot-dot-link-dir-file", data₂)
    test_file("dir/link-dot-dot-file", data₁)
    test_none("dir/link-dot")
    test_none("dir/link-dot-dot")
    test_none("dir/link-dot-dot-dir")
    test_none("dir/link-dot-dot-dir-self")
    test_file("dir/file", data₂)
    rm(dir, recursive=true)
    # check temp dir is empty, remove it
    @test isempty(readdir(tmp))
    rm(tmp)
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

    # In this issue we've seen that symlinking a directory caused files inside
    # the directory to become read-only.  Guard against Tar.jl doing something
    # weird like that.
    @testset "Issue Pkg#2185" begin
        mktempdir() do dir
            root = joinpath(dir, "root")
            target = joinpath("lib", "icu", "67.1")
            link = joinpath("lib", "icu", "current")
            file = joinpath(target, "file")
            dir_mode = 0o755
            file_mode = 0o644
            mkpath(joinpath(root, target))
            touch(joinpath(root, file))
            chmod(joinpath(root, file), dir_mode)
            chmod(joinpath(root, file), file_mode)
            symlink(basename(target), joinpath(root, link))
            tarball = Tar.create(root, joinpath(dir, "test.tar"))
            files = Tar.list(tarball)
            # Make sure the file and the symlink have the expected permissions.
            # Note: in old versions of Julia, the file has always permission 755 on Windows
            @test Tar.Header(replace(file, "\\" => "/"), :file, VERSION ≤ v"1.6.0-DEV.1683" && Sys.iswindows() ? 0o755 : file_mode, 0, "") in files
            @test Tar.Header(replace(link, "\\" => "/"), :symlink, dir_mode, 0, basename(target)) in files
        end
    end
end

@testset "API: list" begin
    dir = make_test_dir()
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    n = length(test_dir_paths)

    # list([callback,] tarball)
    arg_readers(tarball) do tar
        @arg_test tar begin
            headers = Tar.list(tar)
            @test test_dir_paths == [hdr.path for hdr in headers]
        end
        @arg_test tar @test n == tar_count(tar)
        @arg_test tar begin
            Tar.list(tar) do hdr
                @test hdr isa Tar.Header
            end :: Nothing
        end
        local data_pairs
        @arg_test tar begin
            Tar.list(tar) do hdr, data
                @test hdr isa Tar.Header
                @test data isa Vector{Pair{Symbol, String}}
                data_pairs = data
            end :: Nothing
        end
        local data_buffer
        @arg_test tar begin
            Tar.list(tar) do hdr, data::Vector{UInt8}
                @test hdr isa Tar.Header
                @test data isa Vector{UInt8}
                data_buffer = data
            end :: Nothing
        end
        @test join(map(last, data_pairs)) == String(data_buffer)
    end

    # add a sketchy entry to tarball
    open(tarball, append=true) do io
        Tar.write_header(io, Tar.Header("/bad", :file, 0o644, 0, ""))
    end
    paths = push!(copy(test_dir_paths), "/bad")

    # list([callback,] tarball; strict=true|false)
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
    rm(tarball)
end

@testset "API: extract" begin
    dir = make_test_dir()
    hash = tree_hash(dir)
    tarball = Tar.create(dir)
    rm(dir, recursive=true)
    @test hash != Tar.tree_hash(tarball, skip_empty=true)
    @test hash == Tar.tree_hash(tarball, skip_empty=false)

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
                read(tar) # consume the rest
                rm(file)
            end
            # extract(tarball, dir) — non-empty directory (error)
            @arg_test tar begin
                dir = mktempdir()
                touch(joinpath(dir, "file"))
                @test_throws ErrorException Tar.extract(tar, dir)
                read(tar) # consume the rest
                rm(dir, recursive=true)
            end
        end
    end

    NON_STDLIB_TESTS &&
    @testset "inconvenient stream buffering" begin
        # We will try feeding in an adversarial length that used to cause an assertion error
        open(tarball, read=true) do io
            # This will cause an assertion error because we know the padded space beyond the
            # end of the test file content will be larger than 17 bytes, causing the `for`
            # loop to exit early, failing the assertion.
            @test hash == Tar.tree_hash(ChaosBufferStream(io; chunksizes=[17]))
        end

        # This also affected read_data()
        mktempdir() do dir
            open(tarball, read=true) do io
                Tar.extract(ChaosBufferStream(io; chunksizes=[17]), dir)
                check_tree_hash(hash, dir)
            end
        end

        # We also perform a fuzzing test to convince ourselves there are no other errors
        # of this type within `Tar.tree_hash()`.
        for idx in 1:100
            open(tarball, read=true) do io
                @test hash == Tar.tree_hash(ChaosBufferStream(io))
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
        @test hash != Tar.tree_hash(predicate, tarball, skip_empty=true)
        @test hash == Tar.tree_hash(predicate, tarball, skip_empty=false)

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
                read(tar) # consume the rest
                rm(file)
            end
            # extract(predicate, tarball, dir) — non-empty directory (error)
            @arg_test tar begin
                dir = mktempdir()
                touch(joinpath(dir, "file"))
                @test_throws ErrorException Tar.extract(predicate, tar, dir)
                read(tar) # consume the rest
                rm(dir, recursive=true)
            end
        end
    end
    rm(tarball)

    @testset "set_permissions" begin
        tarball, _ = make_test_tarball()
        dir = Tar.extract(tarball, set_permissions=false)
        f_path = joinpath(dir, "0-ffffffff")
        x_path = joinpath(dir, "0-xxxxxxxx")
        @test isfile(f_path)
        @test isfile(x_path)
        if !Sys.iswindows()
            @test !Sys.isexecutable(f_path)
            @test !Sys.isexecutable(x_path)
        end
        @test Sys.isexecutable(f_path) == Sys.isexecutable(x_path)
        rm(dir, recursive=true)
        rm(tarball)
    end
end

@testset "API: rewrite" begin
    # reference standard tarball
    reference, hash₁ = make_test_tarball()
    ref = read(reference)

    # alternate format tarball
    if @isdefined(gtar)
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
    if @isdefined(gtar)
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
        if flag && @isdefined(gtar)
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

if Sys.iswindows() && Sys.which("icacls") !== nothing && VERSION >= v"1.6"
    @testset "windows permissions" begin
        tarball, _ = make_test_tarball()
        mktempdir() do dir
            Tar.extract(tarball, dir)
            f_path = joinpath(dir, "0-ffffffff")
            @test isfile(f_path)
            @test !Sys.isexecutable(f_path)

            x_path = joinpath(dir, "0-xxxxxxxx")
            @test isfile(x_path)
            @test Sys.isexecutable(x_path)

            f_acl = readchomp(`icacls $(f_path)`)
            @test occursin("Everyone:(R,WA)", f_acl)
            x_acl = readchomp(`icacls $(x_path)`)
            @test occursin("Everyone:(RX,WA)", x_acl)
        end
        rm(tarball)
    end
end

@testset "header parsing" begin
    @testset "leading spaces in integer fields" begin
        # fragment of https://sparse.tamu.edu/MM/Oberwolfach/LF10.tar.gz
        tarball = joinpath(test_data_dir, "LF10-fragment.tar")
        hdr = Tar.Header("LF10/LF10_B.mtx", :file, 0o100600, 367, "")
        @test open(Tar.read_header, tarball) == hdr
        @test Tar.list(tarball) == [hdr]
    end
    @testset "header errors" begin
        # generate a valid header
        buf = IOBuffer()
        Tar.write_header(buf, Tar.Header("file", :file, 0o644, 123, ""))
        data = Tar.dump_header(take!(buf))
        notar = "This does not appear to be a TAR file/stream —"
        # test various header problems
        tarball = write_modified_header(data, :version => "AB")
        test_error_prefix("$notar invalid version string for tar file: \"AB\"") do
            open(Tar.read_header, tarball)
        end
        # malformed checksums
        for str in [" ", " "^8, "1HKPhaUq", "\1"]
            tarball = write_modified_header(data, :chksum => str)
            test_error_prefix("$notar malformed chksum field: $(repr(str))") do
                open(Tar.read_header, tarball)
            end
        end
        # incorrect checksum
        tarball = write_modified_header(data, :chksum => "123456\0 ")
        test_error_prefix("$notar incorrect header checksum = 42798;") do
            open(Tar.read_header, tarball)
        end
        # malformed sizes
        for str in [" ", " "^12, "lVonG911HzaL", "\1"]
            tarball = write_modified_header(data, :size => str)
            test_error_prefix("malformed size field: $(repr(str))") do
                open(Tar.read_header, tarball)
            end
        end
        # largest valid binary size
        str = "\0"^3*"\x7f"*"\xff"^7
        tarball = write_modified_header(data, :size => "\x80$str")
        @test open(Tar.read_header, tarball).size == typemax(Int64)
        # smallest too large binary size
        str = "\0"^3*"\x80"*"\x00"^7
        tarball = write_modified_header(data, :size => "\x80$str")
        test_error_prefix("binary integer size value too large: $(repr(str))") do
            open(Tar.read_header, tarball)
        end
        # largest binary size (also too large)
        str = "\xff"^12
        tarball = write_modified_header(data, :size => str)
        test_error_prefix("binary integer size value too large: $(repr(str))") do
            open(Tar.read_header, tarball)
        end
        # malformed modes
        for str in [" ", " "^8, "CbiX4Rkb", "\1"]
            tarball = write_modified_header(data, :mode => str)
            test_error_prefix("malformed mode field: $(repr(str))") do
                open(Tar.read_header, tarball)
            end
        end
        # various valid mode values
        for str in [
                "0", " 0", "  0", "       0",
                "123", " 123", "  00123", "     123",
                "177777", "  177777", "00177777", " 0177777",
            ]
            tarball = write_modified_header(data, :mode => str)
            @test open(Tar.read_header, tarball).mode == parse(Int, str, base=8)
        end
        # smallest & largest too large mode values
        for str in ["200000", "77777777"]
            tarball = write_modified_header(data, :mode => str)
            test_error_prefix("mode value too large: $str") do
                open(Tar.read_header, tarball)
            end
        end
    end
    @testset "octal parsing" begin
        buf = fill(0x0, 512)
        buf[1:21] .= '7'
        # largest valid octal value
        @test Tar.read_header_int(buf, :name) == typemax(Int64)
        # smallest too large octal value
        buf[1] = '1'
        buf[2:22] .= '0'
        test_error_prefix("octal integer name value too large:") do
            Tar.read_header_int(buf, :name)
        end
        # way too large octal value
        for i = 1:length(buf)
            buf[i] = '0' + (i % 8)
        end
        test_error_prefix("octal integer name value too large:") do
            Tar.read_header_int(buf, :name)
        end
    end
end

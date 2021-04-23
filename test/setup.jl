using Test
using Random
using ArgTools

import Tar

include("git_tools.jl")

const NON_STDLIB_TESTS = Main == @__MODULE__

if NON_STDLIB_TESTS
    using SimpleBufferStream

    using Tar_jll
    if isdefined(Tar_jll, :tar)
        const gtar = Tar_jll.tar
    end
end

macro test_throws_broken(E, expr)
    :(@test_broken try $(esc(expr)) catch err err end isa $(esc(E)))
end

tree_hash(path::AbstractString) = bytes2hex(GitTools.tree_hash(path))

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

const empty_tree_sha1 =
    "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
const empty_tree_sha256 =
    "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

function test_empty_hashes(tarball::AbstractString)
    @test empty_tree_sha1 == Tar.tree_hash(tarball, skip_empty=true)
    @test empty_tree_sha1 == Tar.tree_hash(tarball, skip_empty=false)
    @test empty_tree_sha1 == Tar.tree_hash(tarball, algorithm="git-sha1")
    @test empty_tree_sha256 == Tar.tree_hash(tarball, algorithm="git-sha256")
    open(tarball) do io
        @test empty_tree_sha1 == Tar.tree_hash(io, skip_empty=true)
    end
    open(tarball) do io
        @test empty_tree_sha1 == Tar.tree_hash(io, skip_empty=false)
    end
    open(tarball) do io
        @test empty_tree_sha1 == Tar.tree_hash(io, algorithm="git-sha1")
    end
    open(tarball) do io
        @test empty_tree_sha256 == Tar.tree_hash(io, algorithm="git-sha256")
    end
end

function check_tree_hash(hash::AbstractString, root::AbstractString)
    @test tree_hash(root) == hash
    rm(root, recursive=true)
end

function make_test_dir(gen_skip::Bool=false)
    dir = mktempdir()
    touch(joinpath(dir, "file"))
    if gen_skip
        touch(joinpath(dir, "file.skip"))
    end
    mkdir(joinpath(dir, "dir"))

    # Create a file that actually has content
    fpath = joinpath(dir, "dir", "file")
    touch(fpath)
    open(fpath, write=true) do io
        write(io, rand(UInt8, 1000))
    end
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

const test_dir_paths = ["dir", "dir/file", "empty", "file", "link"]
Sys.iswindows() && pop!(test_dir_paths)

# uses Tar.list(callback, tarball) API
function tar_count(tarball; kwargs...)
    n = 0
    Tar.list(tarball; kwargs...) do hdr
        n += 1
    end
    return n
end

function tar_write_file(io::IO, path::String, data::String, mode::Integer=0o644)
    n = ncodeunits(data)
    Tar.write_header(io, Tar.Header(path, :file, mode, n, ""))
    Tar.write_data(io, IOBuffer(data), size=n)
end

function tar_write_link(io::IO, path::String, link::String, mode::Integer=0o755)
    Tar.write_header(io, Tar.Header(path, :symlink, mode, 0, link))
end

function tar_write_dir(io::IO, path::String, mode::Integer=0o755)
    Tar.write_header(io, Tar.Header(path, :directory, mode, 0, ""))
end

"""
    ChaosBufferStream(input::IO; chunksizes, sleepamnts)

Acts as a highly-inconvenient BufferStream, allowing tests to purposefully break
up their data flow reads/writes into chunks of random size (taken via `rand(chunksizes)`)
and with a pause of `rand(sleepamnts)` in between each chunk.

Usage example:

    t_hash = Tar.tree_hash(ChaosBufferStream(io))

Or slightly more complicated:

    http_io = BufferStream()
    @async HTTP.get(url; response_stream=http_io)
    t_hash = Tar.tree_hash(ChaosBufferStream(http_io; chunksizes=4000:8000, sleepamnts=[1e-3, 2e-3]))
"""
function ChaosBufferStream(input::IO; chunksizes = 1024:2048, sleepamnts = 1e-3:1e-4:5e-3)
    output = BufferStream()
    @async begin
        while !eof(input)
            sleep(rand(sleepamnts))
            chunk = read(input, rand(chunksizes))
            write(output, chunk)
        end
        close(output)
    end
    return output
end

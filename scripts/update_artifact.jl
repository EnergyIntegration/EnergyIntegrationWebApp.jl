using Downloads
using Pkg
using SHA
using Tar

const ARTIFACT_NAME = "webapp_dist"
const FRONTEND_REPO = "https://github.com/EnergyIntegration/EnergyIntegrationWebApp"

function artifact_url(version::AbstractString)
    v = startswith(version, "v") ? version[2:end] : version
    return "$(FRONTEND_REPO)/releases/download/v$(v)/EnergyIntegrationWebApp-$(v)-dist.tar.gz"
end

function resolve_url(arg::AbstractString)
    startswith(arg, "http://") || startswith(arg, "https://") ? arg : artifact_url(arg)
end

function extract_tarball!(tarball::AbstractString, dest::AbstractString)
    run(`tar -xzf $tarball -C $dest`)
end

function compute_sha256(path::AbstractString)
    open(path, "r") do io
        return bytes2hex(sha256(io))
    end
end

main(arg::AbstractString) = main([arg])

function main(args)
    isempty(args) && error("Usage: julia scripts/update_artifact.jl <version|url>")
    url = resolve_url(args[1])
    println("Downloading: ", url)
    tarball = Downloads.download(url)
    sha256_hex = compute_sha256(tarball)

    hash = Pkg.Artifacts.create_artifact() do dir
        extract_tarball!(tarball, dir)
    end

    artifacts_toml = joinpath(@__DIR__, "..", "Artifacts.toml")
    Pkg.Artifacts.bind_artifact!(
        artifacts_toml,
        ARTIFACT_NAME,
        hash;
        download_info=[(url, sha256_hex)],
        lazy=true,
        force=true,
    )

    println("Updated Artifacts.toml")
    println("git-tree-sha1 = ", hash)
    println("sha256 = ", sha256_hex)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end

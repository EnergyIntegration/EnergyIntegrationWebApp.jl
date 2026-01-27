using EnergyIntegrationWebApp
using Documenter

DocMeta.setdocmeta!(EnergyIntegrationWebApp, :DocTestSetup, :(using EnergyIntegrationWebApp); recursive=true)

makedocs(;
    modules=[EnergyIntegrationWebApp],
    authors="karei <abcdvvvv@gmail.com>",
    sitename="EnergyIntegrationWebApp.jl",
    format=Documenter.HTML(;
        canonical="https://EnergyIntegration.github.io/EnergyIntegrationWebApp.jl",
        edit_link="master",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
    ],
)

deploydocs(;
    repo="github.com/abcdvvvv/EnergyIntegrationWebApp.jl",
    devbranch="master",
)

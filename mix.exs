defmodule MobWebView.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_webview,
      version: "0.1.0",
      elixir: "~> 1.19",
      erlc_paths: ["src"],
      deps: [{:mob, "~> 0.9.27"}, {:mob_dev, "~> 0.7.31", only: :dev, runtime: false}],
      description: "A standalone Mob native WebView component",
      package: [licenses: ["MIT"], files: ~w(lib src priv LICENSE LICENSES README.md mix.exs)]
    ]
  end

  def application, do: [extra_applications: [:logger], mod: {MobWebView.Application, []}]
end

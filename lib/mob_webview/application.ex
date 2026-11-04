defmodule MobWebView.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link([{Registry, keys: :unique, name: MobWebView.Registry}],
      strategy: :one_for_one
    )
  end
end

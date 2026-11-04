defmodule MobWebView do
  @moduledoc """
  Independent native WebView. No asset caching is implemented yet.

  Commands target a view owned by the calling screen process. Events arrive as
  `{:mob_webview, id, event, payload}` in that screen's `handle_info/2`.
  """
  def view(opts) do
    id = Keyword.fetch!(opts, :id)
    unless is_atom(id) and not is_nil(id), do: raise(ArgumentError, "id must be an atom")
    Mob.UI.native_view(MobWebView.View, Keyword.merge(opts, owner: self()))
  end

  def go_back(id), do: command(id, "go_back", %{})
  def go_forward(id), do: command(id, "go_forward", %{})
  def reload(id), do: command(id, "reload", %{})
  def eval_js(id, code) when is_binary(code), do: command(id, "eval_js", %{code: code})
  def post_message(id, data), do: command(id, "post_message", %{data: data})

  defp command(id, action, payload) do
    case Registry.lookup(MobWebView.Registry, {self(), id}) do
      [{pid, _}] ->
        request = System.unique_integer([:positive, :monotonic])
        send(pid, {:webview_command, Map.merge(payload, %{id: request, action: action})})
        {:ok, request}

      [] ->
        {:error, :not_mounted}
    end
  end

  @doc false
  def install do
    :mob_webview_nif.install()
  end
end

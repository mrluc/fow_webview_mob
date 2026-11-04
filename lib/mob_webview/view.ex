defmodule MobWebView.View do
  use Mob.Component

  @props [
    :url,
    :bundle,
    :allow,
    :active,
    :handle_back,
    :width,
    :height,
    :weight,
    :fill_width,
    :fill_height
  ]
  def mount(props, socket) do
    owner = Map.fetch!(props, :owner)
    id = Map.fetch!(props, :id)
    {:ok, _} = Registry.register(MobWebView.Registry, {owner, id}, nil)

    {:ok,
     Mob.Socket.assign(socket, %{
       owner: owner,
       id: id,
       props: Map.take(props, @props),
       commands: []
     })}
  end

  def update(props, socket), do: {:ok, Mob.Socket.assign(socket, :props, Map.take(props, @props))}
  def render(assigns), do: Map.put(assigns.props, :command, List.first(assigns.commands))

  def handle_info({:webview_command, command}, socket) do
    {:noreply, Mob.Socket.assign(socket, :commands, socket.assigns.commands ++ [command])}
  end

  def handle_event("command_done", %{"id" => id}, socket) do
    commands =
      case socket.assigns.commands do
        [%{id: ^id} | rest] -> rest
        other -> other
      end

    {:noreply, Mob.Socket.assign(socket, :commands, commands)}
  end

  def handle_event(event, payload, socket) do
    send(socket.assigns.owner, {:mob_webview, socket.assigns.id, event, payload})
    {:noreply, socket}
  end
end

defmodule MobWebViewTest do
  use ExUnit.Case, async: true

  test "component builds a native view owned by its screen" do
    node = MobWebView.view(id: :web, url: "https://example.com", allow: ["https://example.com/"])
    assert node.type == :native_view
    assert node.props.module == MobWebView.View
    assert node.props.owner == self()
    assert {:error, :not_mounted} = MobWebView.reload(:missing)
  end

  test "queued commands survive prop updates and advance only after native acknowledgment" do
    node = MobWebView.view(id: :web, url: "https://example.com")
    {:ok, socket} = MobWebView.View.mount(node.props, Mob.Socket.new(MobWebView.View))
    {:ok, first} = MobWebView.go_back(:web)
    assert_receive {:webview_command, command}
    assert command.id == first
    {:noreply, socket} = MobWebView.View.handle_info({:webview_command, command}, socket)

    {:noreply, socket} =
      MobWebView.View.handle_info({:webview_command, %{id: first + 1, action: "reload"}}, socket)

    {:ok, socket} = MobWebView.View.update(node.props, socket)
    assert MobWebView.View.render(socket.assigns).command.id == first
    {:noreply, unchanged} = MobWebView.View.handle_event("command_done", %{"id" => -1}, socket)
    assert unchanged == socket
    {:noreply, socket} = MobWebView.View.handle_event("command_done", %{"id" => first}, socket)
    assert MobWebView.View.render(socket.assigns).command.action == "reload"

    {:noreply, _} =
      MobWebView.View.handle_event("message", %{"data" => %{"hello" => true}}, socket)

    assert_receive {:mob_webview, :web, "message", %{"data" => %{"hello" => true}}}
  end
end

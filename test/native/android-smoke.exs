# Run from a generated Mob app that depends on mob_webview, after native deploy:
#   mix run --no-start /path/to/mob_webview/test/native/android-smoke.exs
# Optional: MOB_WEBVIEW_ANDROID_DEVICE=emulator-5554
# Uses Mob's existing connector and remote test APIs. No new Mix task, APK build,
# instrumentation package, HTTP server, or host-project edits are installed.
Mix.Task.run("app.config")

source = ~S'''
defmodule MobWebView.AndroidSmoke.Screen do
  use Mob.Screen

  def mount(params, _, socket) do
    {:ok, Mob.Socket.assign(socket, %{url: params.url, allow: params.allow, events: []})}
  end

  def render(assigns) do
    ~MOB"""
    <Column fill_width={true} fill_height={true}>
      {MobWebView.view(id: :site, url: @url, allow: @allow, fill_width: true, fill_height: true)}
    </Column>
    """
  end

  def handle_info({:qa_command, caller, reference, action, argument}, socket) do
    result = case action do
      :eval_js -> MobWebView.eval_js(:site, argument)
      :go_back -> MobWebView.go_back(:site)
      :go_forward -> MobWebView.go_forward(:site)
      :reload -> MobWebView.reload(:site)
      :post_message -> MobWebView.post_message(:site, argument)
    end
    send(caller, {:qa_command, reference, result})
    {:noreply, socket}
  end

  def handle_info({:qa_url, url}, socket), do: {:noreply, Mob.Socket.assign(socket, :url, url)}

  def handle_info({:mob_webview, :site, event, payload}, socket) do
    # This is deliberately a real JS → native → component → owning screen →
    # native → JS reply. A direct eval setting a flag would not test the bridge.
    if event == "message" do
      case payload do
        %{"data" => %{"kind" => "ping", "value" => value}} ->
          MobWebView.post_message(:site, %{kind: "pong", value: value})
        _ -> :ok
      end
    end
    events = Enum.take([{event, payload} | socket.assigns.events], 200)
    {:noreply, Mob.Socket.assign(socket, :events, events)}
  end

  def handle_info(_, socket), do: {:noreply, socket}
end
'''

# Compile against the host's exact Mob dependency; transfer only this test module.
modules = Code.compile_string(source, "mob_webview_android_smoke.exs")

serials =
  case System.get_env("MOB_WEBVIEW_ANDROID_DEVICE") do
    nil -> []
    serial -> [serial]
  end

# Mob's current restart helper assumes package/.MainActivity. The generated
# wrapper has a customized applicationId and a different Kotlin namespace,
# so ask Android for the actual launch component instead of guessing its name.
if serials != [] do
  serial = hd(serials)
  package = MobDev.Config.bundle_id()

  {resolved, 0} =
    System.cmd("adb", [
      "-s",
      serial,
      "shell",
      "cmd",
      "package",
      "resolve-activity",
      "--brief",
      package
    ])

  component = resolved |> String.split("\n", trim: true) |> Enum.find(&String.contains?(&1, "/"))
  unless component, do: raise("Android could not resolve the app's launch activity")
  MobDev.Connector.start_epmd()
  {_, 0} = System.cmd("adb", ["-s", serial, "reverse", "tcp:4369", "tcp:4369"])
  {_, 0} = System.cmd("adb", ["-s", serial, "shell", "am", "force-stop", package])
  {_, 0} = System.cmd("adb", ["-s", serial, "shell", "am", "start", "-W", "-n", component])
  # Attach deliberately has a short timeout; wait for the real delayed Mob
  # distribution registration rather than racing its cold-start delay.
  prefix = Atom.to_string(Mix.Project.config()[:app]) <> "_android"
  deadline = System.monotonic_time(:millisecond) + 20_000

  await_dist = fn recur ->
    unless Enum.any?(MobDev.Tunnel.epmd_names(), fn {name, _} ->
             String.starts_with?(name, prefix)
           end) do
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("App did not register its development connection")

      Process.sleep(100)
      recur.(recur)
    end
  end

  await_dist.(await_dist)
end

{devices, _failed} =
  MobDev.Connector.connect_all(
    platforms: [:android],
    only: serials,
    restart: false,
    name: String.to_atom("mob_webview_qa_#{System.pid()}@127.0.0.1")
  )

unless length(devices) == 1 do
  raise "Expected one connected Android app; set MOB_WEBVIEW_ANDROID_DEVICE to select its serial"
end

node = hd(devices).node

for {module, binary} <- modules do
  {:module, ^module} =
    :rpc.call(node, :code, :load_binary, [module, ~c"mob_webview_android_smoke.exs", binary])
end

# The existing generated Counter wrapper has a deterministic local public server
# containing / and /counters/one. It runs on the phone; no adb reverse is needed.
url = :rpc.call(node, CountersMobile.PublicShell, :url, [])
unless is_binary(url), do: raise("Counter public-shell server is unavailable: #{inspect(url)}")
uri = URI.parse(url)
origin = URI.to_string(%{uri | path: nil, query: nil, fragment: nil})
allow = [origin <> "/"]
original_screen = Mob.Test.screen(node)

wait = fn label, predicate ->
  deadline = System.monotonic_time(:millisecond) + 20_000

  poll = fn poll ->
    case predicate.() do
      value when value not in [false, nil] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: raise("Timed out waiting for #{label}")

        Process.sleep(25)
        poll.(poll)
    end
  end

  poll.(poll)
end

events = fn ->
  case Mob.Test.assigns(node) do
    %{events: events} -> events
    other -> raise "QA screen unavailable: #{inspect(other)}"
  end
end

command = fn action, argument ->
  reference = make_ref()
  :ok = Mob.Test.send_message(node, {:qa_command, self(), reference, action, argument})

  receive do
    {:qa_command, ^reference, {:ok, id}} -> id
    {:qa_command, ^reference, other} -> raise "Command #{action} failed: #{inspect(other)}"
  after
    5_000 -> raise "Owning screen did not accept command #{action}"
  end
end

evaluate = fn javascript ->
  id = command.(:eval_js, javascript)

  {_event, payload} =
    wait.("JavaScript evaluation", fn ->
      Enum.find(events.(), fn {event, payload} ->
        event == "eval_result" && payload["id"] == id
      end)
    end)

  payload["result"]
end

loaded = fn target ->
  Enum.count(events.(), fn {event, payload} -> event == "loaded" && payload["url"] == target end)
end

check = fn condition, message -> unless condition, do: raise(message) end

:ok = Mob.Test.navigate(node, MobWebView.AndroidSmoke.Screen, %{url: url, allow: allow})

qa_pid =
  wait.("QA screen mount", fn ->
    Enum.find_value(Mob.Test.screens(node), fn
      {_, MobWebView.AndroidSmoke.Screen, pid} -> pid
      _ -> nil
    end)
  end)

try do
  wait.("initial public page", fn -> loaded.(url) > 0 end)
  check.(evaluate.("1 + 2") == 3, "JavaScript evaluation returned the wrong result")

  evaluate.(~S'''
    window.__mobQAReply = null;
    window.mob.onMessage(value => { window.__mobQAReply = value; });
    window.mob.send({kind: "ping", value: "android-smoke"});
    true;
  ''')

  wait.("JS to Elixir to JS round trip", fn ->
    evaluate.("window.__mobQAReply") == %{"kind" => "pong", "value" => "android-smoke"}
  end)

  IO.puts("PASS: JavaScript evaluation and JS → Elixir → JS round trip")

  next = origin <> "/counters/one"
  :ok = Mob.Test.send_message(node, {:qa_url, next})
  wait.("second page", fn -> loaded.(next) > 0 end)
  before = loaded.(url)
  command.(:go_back, nil)
  wait.("browser Back", fn -> loaded.(url) > before end)
  check.(evaluate.("location.href") == url, "Back did not restore the original page")
  before = loaded.(next)
  command.(:go_forward, nil)
  wait.("browser Forward", fn -> loaded.(next) > before end)
  check.(evaluate.("location.href") == next, "Forward did not restore the second page")
  before = loaded.(next)
  command.(:reload, nil)
  wait.("browser reload", fn -> loaded.(next) > before end)
  IO.puts("PASS: stable component URL updates, Back, Forward, and reload")

  target = "https://not-allowed.invalid/mob-webview-smoke"
  evaluate.("setTimeout(() => location.assign(#{inspect(target)}), 0); true")

  wait.("blocked navigation event", fn ->
    Enum.any?(events.(), fn {event, payload} -> event == "blocked" && payload["url"] == target end)
  end)

  check.(evaluate.("location.href") == next, "Blocked navigation changed the displayed page")
  IO.puts("PASS: denied navigation leaves the current page available")
  IO.puts("Android MobWebView native smoke test passed.")
rescue
  error ->
    IO.inspect(Mob.Test.assigns(node), label: "QA assigns at failure", limit: 20)

    IO.inspect(Mob.Test.tree(node),
      label: "QA rendered tree at failure",
      limit: 35,
      printable_limit: 2000
    )

    reraise error, __STACKTRACE__
after
  # QA module remains loaded only in RAM; removing its screen destroys its view.
  :ok = Mob.Test.pop_to(node, original_screen)
  wait.("original screen restoration", fn -> Mob.Test.screen(node) == original_screen end)

  wait.("component registration cleanup", fn ->
    :rpc.call(node, Registry, :lookup, [MobWebView.Registry, {qa_pid, :site}]) == []
  end)

  IO.puts("PASS: original screen restored and QA component registration released")
end

defmodule MobWebView.BundleTest do
  use ExUnit.Case, async: true

  setup do
    root =
      Path.join(System.tmp_dir!(), "mob-webview-bundle-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.write!(Path.join(root, "startup.html"), "<html></html>")
    %{root: root}
  end

  defp manifest(root, file) do
    File.write!(
      Path.join(root, "native.json"),
      :json.encode(%{
        "schema" => 1,
        "startup" => "startup.html",
        "files" => %{
          "https://example.com/app.js" => %{"file" => file, "mime" => "text/javascript"}
        }
      })
    )
  end

  test "resolves only declared regular files", %{root: root} do
    manifest(root, "startup.html")
    bundle = MobWebView.Bundle.load!(root)
    assert bundle["startup"] == Path.join(root, "startup.html")
    assert bundle["files"]["https://example.com/app.js"]["file"] == bundle["startup"]
  end

  test "rejects traversal, absolute paths and symlinks", %{root: root} do
    for file <- ["../startup.html", "/etc/passwd", "../", "bad\\file"] do
      manifest(root, file)
      assert_raise ArgumentError, fn -> MobWebView.Bundle.load!(root) end
    end

    File.ln_s!(Path.join(root, "startup.html"), Path.join(root, "linked.html"))
    manifest(root, "linked.html")
    assert_raise ArgumentError, fn -> MobWebView.Bundle.load!(root) end
  end
end

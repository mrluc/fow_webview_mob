defmodule MobWebView.Bundle do
  @moduledoc "Load an allowlisted native bundle from this application's private files."
  def load!(root) do
    root = Path.expand(root)
    manifest = root |> Path.join("native.json") |> File.read!() |> :json.decode()
    unless manifest["schema"] == 1, do: raise(ArgumentError, "Unsupported native bundle")

    files =
      Map.new(manifest["files"], fn {url, file} ->
        {url, Map.put(file, "file", resolve!(root, file["file"]))}
      end)

    Map.merge(manifest, %{"files" => files, "startup" => resolve!(root, manifest["startup"])})
  end

  defp resolve!(root, path) do
    unless is_binary(path) && Path.type(path) == :relative &&
             !String.contains?(path, ["\\", "\0"]) &&
             Enum.all?(Path.split(path), &(&1 not in [".", ".."])),
           do: raise(ArgumentError, "Invalid bundle file")

    Enum.reduce(Path.split(path), root, fn part, parent ->
      file = Path.join(parent, part)

      if File.lstat!(file).type == :symlink,
        do: raise(ArgumentError, "Bundle symlinks are not allowed")

      file
    end)
    |> tap(fn file ->
      unless File.regular?(file), do: raise(ArgumentError, "Missing bundle file")
    end)
  end
end

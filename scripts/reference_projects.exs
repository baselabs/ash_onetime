defmodule AshOnetime.ReferenceProjects do
  @moduledoc false

  # Projects this package must never depend on or name. The list holds SHA-256 digests of
  # lower-cased identifier tokens, so the public tree enforces the boundary without
  # publishing the names. The control token is listed so checks can prove they fire.
  @digests MapSet.new([
             "9c077fe75d99a8e03a03067323edf30fb1186deba4d9c280048be456c69949d1",
             "1c5149c8632269dc32855f95a88a16a596702ea5f44d3bdd3ef14d8fb0f315fa",
             "babf04b9c9ed56b17de055edd223824e5359aa5aec4506f0d9c4a15bbfc1d247",
             "cd57abf9fb37cd0fb417d27bd1c79ec6e4879e43c99ea2f6ed39b6f5a39ae2a7",
             "cb6e72f7e4ee0d93993e37b7ad13a271a154035ded0bdb94819d20254e3a3d55"
           ])

  @control "reference_project_denylist_control"

  @doc "A listed token that carries no real name; checks use it as their positive control."
  def control, do: @control

  @doc "True when `name` (an atom or string) is a listed token."
  def listed?(name) when is_atom(name), do: listed?(Atom.to_string(name))

  def listed?(name) when is_binary(name) do
    digest = :crypto.hash(:sha256, String.downcase(name)) |> Base.encode16(case: :lower)
    MapSet.member?(@digests, digest)
  end

  @doc "True when any identifier-shaped token in `text` is listed."
  def mentioned?(text) when is_binary(text) do
    ~r/[a-z0-9_]+/
    |> Regex.scan(String.downcase(text))
    |> Enum.uniq()
    |> Enum.any?(fn [token] -> listed?(token) end)
  end
end

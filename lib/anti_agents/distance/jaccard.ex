defmodule AntiAgents.Distance.Jaccard do
  @moduledoc """
  Lexical token-set Jaccard similarity backend.
  """

  @behaviour AntiAgents.Distance

  @impl AntiAgents.Distance
  @spec pairwise(String.t(), String.t(), keyword()) :: {:ok, float()}
  def pairwise(a, b, _opts \\ []) do
    {:ok, similarity(a, b)}
  end

  @impl AntiAgents.Distance
  @spec embed([String.t()], keyword()) :: {:error, :not_supported}
  def embed(_texts, _opts), do: {:error, :not_supported}

  @spec similarity(String.t(), String.t()) :: float()
  def similarity(a, b) do
    left = token_set(a)
    right = token_set(b)
    union = MapSet.union(left, right) |> MapSet.size()

    if union == 0 do
      0.0
    else
      MapSet.intersection(left, right)
      |> MapSet.size()
      |> Kernel./(union)
    end
  end

  defp token_set(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/, trim: true)
    |> MapSet.new()
  end
end

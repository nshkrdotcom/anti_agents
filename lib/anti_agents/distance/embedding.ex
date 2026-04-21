defmodule AntiAgents.Distance.Embedding do
  @moduledoc """
  Embedding cosine-similarity backend with an injectable embedding client.

  Callers pass `:embedding_client`, a module implementing `embed/2`. The
  production CLI path uses `AntiAgents.Embedding.GeminiClient`; tests can inject
  deterministic clients through the same seam.
  """

  @behaviour AntiAgents.Distance

  @impl AntiAgents.Distance
  @spec pairwise(String.t(), String.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def pairwise(a, b, opts \\ []) do
    with {:ok, [left, right]} <- embed([a, b], opts) do
      {:ok, cosine(left, right)}
    end
  end

  @impl AntiAgents.Distance
  @spec embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed(texts, opts) when is_list(texts) do
    case Keyword.get(opts, :embedding_client) do
      nil -> {:error, :embedding_client_not_configured}
      client -> client.embed(texts, opts)
    end
  end

  @spec cosine([number()], [number()]) :: float()
  def cosine(left, right) do
    dot =
      left
      |> Enum.zip(right)
      |> Enum.map(fn {a, b} -> a * b end)
      |> Enum.sum()

    left_norm = norm(left)
    right_norm = norm(right)

    if left_norm == 0.0 or right_norm == 0.0 do
      0.0
    else
      dot / (left_norm * right_norm)
    end
  end

  defp norm(vector) do
    vector
    |> Enum.map(&(&1 * &1))
    |> Enum.sum()
    |> :math.sqrt()
  end
end

defmodule AntiAgents.Distance.Judge do
  @moduledoc """
  Placeholder for an LLM-as-judge novelty backend.

  The backend is explicit rather than silently falling back to lexical distance:
  callers must configure a judge client before using it for cited evidence.
  """

  @behaviour AntiAgents.Distance

  @impl AntiAgents.Distance
  @spec pairwise(String.t(), String.t(), keyword()) :: {:ok, float()} | {:error, term()}
  def pairwise(a, b, opts \\ []) do
    case Keyword.get(opts, :judge_client) do
      nil -> {:error, :judge_backend_not_configured}
      client -> client.pairwise(a, b, opts)
    end
  end

  @impl AntiAgents.Distance
  @spec embed([String.t()], keyword()) :: {:error, :not_supported}
  def embed(_texts, _opts), do: {:error, :not_supported}
end

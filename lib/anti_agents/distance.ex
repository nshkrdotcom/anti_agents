defmodule AntiAgents.Distance do
  @moduledoc """
  Behaviour for text similarity backends used by frontier scoring.
  """

  @callback pairwise(String.t(), String.t(), keyword()) ::
              {:ok, float()} | {:error, term()}

  @callback embed([String.t()], keyword()) ::
              {:ok, [[float()]]} | {:error, term()}

  @doc """
  Resolves a distance backend name or module.
  """
  @spec resolve(atom() | module() | String.t() | nil) :: module()
  def resolve(nil), do: AntiAgents.Distance.Jaccard
  def resolve(:jaccard), do: AntiAgents.Distance.Jaccard
  def resolve("jaccard"), do: AntiAgents.Distance.Jaccard
  def resolve(:embedding), do: AntiAgents.Distance.Embedding
  def resolve("embedding"), do: AntiAgents.Distance.Embedding
  def resolve(:judge), do: AntiAgents.Distance.Judge
  def resolve("judge"), do: AntiAgents.Distance.Judge
  def resolve(module) when is_atom(module), do: module
end

defmodule AntiAgents.Embedding.GeminiClient do
  @moduledoc """
  Gemini-backed embedding client for `AntiAgents.Distance.Embedding`.

  The adapter uses `gemini_ex` batch embeddings so descriptor fitting and
  pairwise distance calls share one production provider path.
  """

  alias Gemini.Types.Response.BatchEmbedContentsResponse

  @default_model "gemini-embedding-001"
  @default_task_type :clustering
  @default_dimensions 768
  @valid_task_types [
    :retrieval_query,
    :retrieval_document,
    :semantic_similarity,
    :classification,
    :clustering,
    :question_answering,
    :fact_verification,
    :code_retrieval_query
  ]

  @spec embed([String.t()], keyword()) :: {:ok, [[float()]]} | {:error, term()}
  def embed([], _opts), do: {:ok, []}

  def embed(texts, opts) when is_list(texts) do
    gemini = Keyword.get(opts, :gemini_module, Gemini)

    case gemini.batch_embed_contents(texts, request_opts(opts)) do
      {:ok, response} ->
        with {:ok, values} <- extract_values(response),
             :ok <- validate_count(texts, values) do
          {:ok, Enum.map(values, &normalize_values/1)}
        end

      {:error, reason} ->
        {:error, {:gemini_embedding_failed, reason}}

      other ->
        {:error, {:unexpected_gemini_embedding_response, other}}
    end
  end

  def embed(_texts, _opts), do: {:error, :texts_must_be_a_list}

  @spec default_model() :: String.t()
  def default_model, do: @default_model

  @spec default_task_type() :: atom()
  def default_task_type, do: @default_task_type

  @spec default_dimensions() :: pos_integer()
  def default_dimensions, do: @default_dimensions

  @spec normalize_task_type(atom() | String.t() | nil) :: atom()
  def normalize_task_type(nil), do: @default_task_type
  def normalize_task_type(task) when task in @valid_task_types, do: task

  def normalize_task_type(task) when is_binary(task) do
    normalized =
      task
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Enum.find(@valid_task_types, @default_task_type, &(Atom.to_string(&1) == normalized))
  end

  def normalize_task_type(_task), do: @default_task_type

  defp request_opts(opts) do
    [
      model: Keyword.get(opts, :embedding_model, @default_model),
      task_type: opts |> Keyword.get(:embedding_task_type) |> normalize_task_type(),
      output_dimensionality: Keyword.get(opts, :embedding_dimensions, @default_dimensions)
    ]
    |> maybe_put(:auth, Keyword.get(opts, :embedding_auth))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp extract_values(%BatchEmbedContentsResponse{} = response) do
    {:ok, BatchEmbedContentsResponse.get_all_values(response)}
  end

  defp extract_values(%{embeddings: embeddings}) when is_list(embeddings) do
    {:ok, Enum.map(embeddings, &embedding_values/1)}
  end

  defp extract_values(%{"embeddings" => embeddings}) when is_list(embeddings) do
    {:ok, Enum.map(embeddings, &embedding_values/1)}
  end

  defp extract_values(other), do: {:error, {:invalid_embedding_response, other}}

  defp embedding_values(%{values: values}) when is_list(values), do: float_values(values)
  defp embedding_values(%{"values" => values}) when is_list(values), do: float_values(values)
  defp embedding_values(%{"embedding" => embedding}), do: embedding_values(embedding)
  defp embedding_values(%{embedding: embedding}), do: embedding_values(embedding)
  defp embedding_values(_other), do: []

  defp float_values(values), do: Enum.map(values, &(&1 * 1.0))

  defp validate_count(texts, values) do
    if length(texts) == length(values) and Enum.all?(values, &(&1 != [])) do
      :ok
    else
      {:error, {:embedding_count_mismatch, expected: length(texts), got: length(values)}}
    end
  end

  defp normalize_values(values) when length(values) == 3072, do: values

  defp normalize_values(values) do
    magnitude =
      values
      |> Enum.map(&(&1 * &1))
      |> Enum.sum()
      |> :math.sqrt()

    if magnitude == 0.0 do
      values
    else
      Enum.map(values, &(&1 / magnitude))
    end
  end
end

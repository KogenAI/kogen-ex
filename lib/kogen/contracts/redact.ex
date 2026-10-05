defmodule Kogen.Contracts.Redact do
  @moduledoc """
  Strips credentials from text Kogen prints, journals or logs: bearer values, token and API key
  fields, and JWT-shaped strings. OTP crash reports are dropped whole, because they carry
  process state such as an HTTP client's request headers.
  """

  @placeholder "[REDACTED]"
  @filter_id :kogen_redact

  # The value stops before a quote, backslash, separator or closing bracket, so redacting an
  # encoded JSON line or an inspected term keeps it well formed.
  @value ~S|[^\s"'\\,;&}\])]+|
  @bearer Regex.compile!("(bearer\\s+)" <> @value, "i")
  @field Regex.compile!(
           "((?:access_token|refresh_token|id_token|api[_-]?key)\\\\?[\"']?\\s*(?:=>|:|=)\\s*" <>
             "(?:~c)?\\\\?[\"']?)" <> @value,
           "i"
         )
  @jwt ~r/eyJ[A-Za-z0-9_\-.]{37,}/

  @doc "Returns `text` with every credential-shaped value replaced."
  @spec text(String.t()) :: String.t()
  def text(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@bearer, &1, "\\1" <> @placeholder))
    |> then(&Regex.replace(@field, &1, "\\1" <> @placeholder))
    |> then(&Regex.replace(@jwt, &1, @placeholder))
  end

  @doc "Inspects `term` for an error message, with credentials redacted."
  @spec inspect(term()) :: String.t()
  def inspect(term), do: term |> Kernel.inspect() |> text()

  @doc "Installs the primary logger filter that applies `log_filter/2` to every log event."
  @spec install_log_filter() :: :ok | {:error, term()}
  def install_log_filter do
    _ = :logger.remove_primary_filter(@filter_id)
    :logger.add_primary_filter(@filter_id, {&__MODULE__.log_filter/2, :none})
  end

  @doc "Drops OTP reports and redacts every other log message."
  @spec log_filter(:logger.log_event(), term()) :: :logger.filter_return()
  def log_filter(%{meta: %{domain: [:otp | _]}}, _arg), do: :stop
  def log_filter(%{msg: {:report, %{label: _label}}}, _arg), do: :stop
  def log_filter(%{msg: msg} = event, _arg), do: %{event | msg: {:string, message(msg)}}

  # A crashing filter is removed by the logger, so a malformed message must not raise here.
  defp message(msg) do
    msg |> chardata() |> IO.chardata_to_string() |> text()
  rescue
    _error in [ArgumentError, UnicodeConversionError] -> "[unformattable log message]"
  end

  defp chardata({:string, chardata}), do: chardata
  defp chardata({:report, report}), do: Kernel.inspect(report)
  defp chardata({format, args}), do: :io_lib.format(format, args)
end

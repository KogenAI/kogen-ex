defmodule Kogen.Contracts.RedactTest do
  use ExUnit.Case, async: true

  alias Kogen.Contracts.Redact

  @jwt "eyJhbGciOiJSUzI1NiJ9." <> String.duplicate("fAkEpAyLoAd", 4) <> ".c2ln"

  test "bearer values, token fields and JWTs are replaced wherever they appear" do
    cases = [
      ~s({~c"authorization", ~c"Bearer #{@jwt}"}),
      "Authorization: bearer opaque-fake-value",
      ~s({"access_token":"fake-access","refresh_token":"fake-refresh"}),
      ~s(detail: "{\\"id_token\\":\\"fake-id\\"}"),
      "grant_type=refresh_token&refresh_token=fake-refresh&client_id=app",
      ~s(%{api_key: "fake-key", "apiKey" => "fake-key"}),
      "a bare #{@jwt} in text"
    ]

    for text <- cases do
      redacted = Redact.text(text)
      assert redacted =~ "[REDACTED]"

      for secret <- [@jwt, "opaque-fake-value", "fake-access", "fake-refresh", "fake-id"],
          do: refute(redacted =~ secret)

      refute redacted =~ "fake-key"
    end

    assert Redact.text(~s({"access_token":"fake-access","ok":1})) ==
             ~s({"access_token":"[REDACTED]","ok":1})
  end

  test "ordinary text and short base64 are left alone" do
    text = "token budget 4096; eyJshort; tokens: %{input: 10}; Bearer"
    assert Redact.text(text) == text
  end

  test "inspect redacts the inspected term" do
    assert Redact.inspect({:error, %{headers: [{"authorization", "Bearer " <> @jwt}]}}) ==
             ~s({:error, %{headers: [{"authorization", "Bearer [REDACTED]"}]}})
  end

  test "the log filter drops OTP reports and redacts every other message" do
    otp = %{level: :error, msg: {:string, "State: #{@jwt}"}, meta: %{domain: [:otp, :sasl]}}
    assert Redact.log_filter(otp, :none) == :stop

    crash = %{level: :error, msg: {:report, %{label: {:gen_server, :terminate}}}, meta: %{}}
    assert Redact.log_filter(crash, :none) == :stop

    for msg <- [{:string, ["Bearer ", @jwt]}, {~c"token ~s", [@jwt]}, {:report, %{t: @jwt}}] do
      assert %{msg: {:string, text}} =
               Redact.log_filter(%{level: :info, msg: msg, meta: %{}}, :none)

      assert text =~ "[REDACTED]"
      refute text =~ @jwt
    end

    bad = %{level: :info, msg: {~c"~s ~s", [:one]}, meta: %{}}
    assert %{msg: {:string, "[unformattable log message]"}} = Redact.log_filter(bad, :none)
  end
end

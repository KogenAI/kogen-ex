Rails.application.routes.draw do
  get "/greeting", to: "greetings#show"
end

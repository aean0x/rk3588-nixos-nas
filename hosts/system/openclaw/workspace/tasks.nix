# Lobster workflow starter templates (.lobster YAML).
{ pkgs }:
let
  yaml = pkgs.formats.yaml { };
in
{
  "jacket-advice.lobster" = yaml.generate "jacket-advice.lobster" {
    name = "jacket-advice";
    args.location.default = "Phoenix";
    steps = [
      {
        id = "fetch";
        run = "weather --json \${location}";
      }
      {
        id = "confirm";
        approval = "Want jacket advice from the LLM?";
        stdin = "\$fetch.json";
      }
      {
        id = "advice";
        pipeline = "llm.invoke --prompt \"Given this weather data, should I wear a jacket? Be concise and return JSON.\"";
        stdin = "\$fetch.json";
        when = "\$confirm.approved";
      }
    ];
  };
}

{ lib, pkgs, ... }:
let
  yaml = pkgs.formats.yaml { };
  starters = {
    "inbox-triage.lobster" = yaml.generate "inbox-triage.lobster" {
      name = "inbox-triage";
      args.tag.default = "family";
      steps = [
        {
          id = "collect";
          command = "inbox list --json";
        }
        {
          id = "categorize";
          command = "inbox categorize --json";
          stdin = "\$collect.stdout";
        }
        {
          id = "approve";
          command = "inbox apply --approve";
          stdin = "\$categorize.stdout";
          approval = "required";
        }
        {
          id = "execute";
          command = "inbox apply --execute";
          stdin = "\$categorize.stdout";
          condition = "\$approve.approved";
        }
      ];
    };
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
  };
in
{
  templates = starters;
  persistentMarker = "<!-- OPENCLAW-PERSISTENT-SECTION -->";
  tasksDir = "tasks";
}

import os

from openhands.sdk import LLM, Conversation
from openhands.tools.preset.default import get_default_agent
from openhands_k8s_agent_sandbox import AgentSandboxWorkspace

TASK = (
    "Compare the PyPI packages requests, boto3, kubernetes, litellm and "
    "openhands-sdk using the PyPI JSON API: latest version and number of "
    "releases. Install rich, write report.py that prints the result as a "
    "table sorted by releases, and run it."
)

with AgentSandboxWorkspace(
    warmpool="openhands-pool",
    namespace="agent-sandboxes",
    api_key=os.environ["SANDBOX_SESSION_KEY"],
) as ws:
    llm = LLM(model="bedrock/us.anthropic.claude-sonnet-4-6", aws_region_name="us-east-1")
    agent = get_default_agent(llm=llm, cli_mode=True)
    conversation = Conversation(agent=agent, workspace=ws)
    conversation.send_message(TASK)
    conversation.run()

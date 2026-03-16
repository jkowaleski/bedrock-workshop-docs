# bedrock-workshop-docs
Documentation and key learnings from Amazon Bedrock workshop
# Lab 1 Notes Takeaway

## Functionality:

* Define tools that serve hardcoded data to customers 
* Integrate DuckDuckGo web search so the agent can pull live information
* Sync knowledge base with product technical support files for troubleshooting
* Downsides: Tools all run locally and agent does not have memory

Together, with the above functionality, the agent provides the user with the hardcoded information, as well as information from web searches and technical support files. 

```python
# Define a tool with just a decorator and docstring
@tool
def get_return_policy(product_category: str) -> str:
    """Get return policy information for a specific product category."""
    policy = return_policies.get(product_category.lower(), default_policy)
    return f"Return Policy - {product_category.title()}:\n• Return window: {policy['window']}..."

# Web search via DuckDuckGo
@tool
def web_search(keywords: str, region: str = "us-en", max_results: int = 5) -> str:
    """Search the web for updated information."""
    return DDGS().text(keywords, region=region, max_results=max_results)

# Create the agent — tools are local, no memory
agent = Agent(
    model=BedrockModel(model_id="global.amazon.nova-2-lite-v1:0", temperature=0.3),
    tools=[get_product_info, get_return_policy, web_search, get_technical_support],
    system_prompt=SYSTEM_PROMPT,
)
response = agent("What's the return policy for my thinkpad X1 Carbon?")
```

# Lab 2 Notes Takeaway
### Short Term Memory: Session based memory that doesn't go longer than a single interaction or closely related session
### Long Term Memory: Information is stored across multiple conversations - facts, preferences, summaries
* Asynchronously stored STM to find patterns and important information
* Semantic memory - Uses vector embeddings to store factual information from conversation

```python
# Create memory with two strategies: preferences + semantic
memory = memory_manager.get_or_create_memory(
    name="CustomerSupportMemory",
    strategies=[
        {StrategyType.USER_PREFERENCE.value: {
            "name": "CustomerPreferences",
            "namespaces": ["support/customer/{actorId}/preferences/"],
        }},
        {StrategyType.SEMANTIC.value: {
            "name": "CustomerSupportSemantic",
            "namespaces": ["support/customer/{actorId}/semantic/"],
        }},
    ],
)

# Store a conversation into STM (LTM extraction happens async)
memory_client.create_event(
    memory_id=memory_id, actor_id=ACTOR_ID, session_id="previous_session",
    messages=[("I need a laptop under $1200, prefer ThinkPad.", "USER"),
              ("I'd suggest the ThinkPad E series.", "ASSISTANT")],
)

# Retrieve long-term memories via semantic search
memories = memory_client.retrieve_memories(
    memory_id=memory_id,
    namespace=f"support/customer/{ACTOR_ID}/preferences/",
    query="customer laptop preferences",
)

# Only change from Lab 1: plug in a session manager
agent = Agent(
    model=model, tools=tools, system_prompt=SYSTEM_PROMPT,
    session_manager=AgentCoreMemorySessionManager(memory_config, REGION),
)
```

# Lab 3 Notes Takeaway
* Previously, each agent had its own copy of tools, which is not scalable
    * Code duplication and no centralized security or access control
* This lab creates centralized, reusable tools
* Important Steps: Create function definition metadata and AgentCore Gateway to expose the lambda as compatable endpoiunt
* JWT-based authentication with Cognito Integration and web search is now centralized with AgentCore Gateway
* Limitations: Manual scaling, still running locally 

### AgentCore Identity: seamless agent identity and access management across AWS services and 3rd party applications
* Supports several identity providers 
* **Simple REST Integration and lambda flexibility (MCP endpoints)**
```python
# Create a gateway with JWT auth via Cognito
gateway_client.create_gateway(
    name="customersupport-gw",
    protocolType="MCP",
    authorizerType="CUSTOM_JWT",
    authorizerConfiguration={"customJWTAuthorizer": {
        "allowedClients": [cognito_config["client_id"]],
        "discoveryUrl": cognito_config["discovery_url"],
    }},
)

# Add a Lambda function as a gateway target
gateway_client.create_gateway_target(
    gatewayIdentifier=gateway_id,
    name="LambdaUsingSDK",
    targetConfiguration={"mcp": {"lambda": {
        "lambdaArn": lambda_arn,
        "toolSchema": {"inlinePayload": api_spec},
    }}},
)

# Connect agent to gateway — local tools + remote MCP tools
mcp_client = MCPClient(lambda: streamablehttp_client(
    gateway_url, headers={"Authorization": f"Bearer {bearer_token}"},
))
with mcp_client:
    tools = [get_product_info, get_return_policy, get_technical_support] + mcp_client.list_tools_sync()
    agent = Agent(model=model, tools=tools, system_prompt=SYSTEM_PROMPT)
```

# Lab 4 Notes Takeaway
* AgentCore Runtime - Serverless runtime that deploys your agent as a production endpoint. Solves previous issuea like limited observability, no autoscaling, and the innability to handle concurrent users - only a few limes of code added to make this change
* BedrockAgentCoreApp starts an HTTP server on port 8080
*  agentcore_runtime.launch() builds a container, pushes to ECR, and deploys to AgentCore Runtime
* Limitations: quality checks and UI

```python
# Only 4 lines to make an agent production-ready
from bedrock_agentcore.runtime import BedrockAgentCoreApp

app = BedrockAgentCoreApp()

@app.entrypoint
async def invoke(payload, context=None):
    user_input = payload.get("prompt", "")
    session_id = context.session_id
    auth_header = (context.request_headers or {}).get("Authorization", "")
    # ... build agent with MCP + memory, return response text

if __name__ == "__main__":
    app.run()

# Deploy with the starter toolkit
agentcore_runtime = Runtime()
agentcore_runtime.configure(entrypoint="lab4_runtime.py", execution_role=role_arn, auto_create_ecr=True)
agentcore_runtime.launch(env_vars={"MEMORY_ID": memory_id})

# Invoke the deployed agent
response = agentcore_runtime.invoke(
    {"prompt": "What's the return policy for smartphones?"},
    bearer_token=access_token, session_id=str(uuid.uuid4()),
)
```

# Lab 5 Notes Takeaway
## Monitor Quality
## AgentCore Evaluations: Managed service that automatically samples and scores agent interactions in production:
1. Session sampling — configurable rate (100% for demo, 10-20% in prod)
2. Evaluators — score each sampled session
3. Dashboard — results flow into CloudWatch GenAI Observability

Built in evaluators:
```
- Builtin.GoalSuccessRate — did the agent actually solve the customer's problem?
- Builtin.Correctness — is the information factually accurate?
- Builtin.ToolSelectionAccuracy — did it pick the right tool for the job?
```
* The results can point to improvements like refining prompts, improving tool schemas, updating the knowledg base, etc. 
```python
# Set up continuous online evaluation with built-in evaluators
eval_client = Evaluation(region=region)

eval_client.create_online_config(
    agent_id=agent_id,
    config_name="customer_support_agent_eval",
    sampling_rate=100,
    evaluator_list=["Builtin.GoalSuccessRate", "Builtin.Correctness", "Builtin.ToolSelectionAccuracy"],
    auto_create_execution_role=True,
)
# Results appear in CloudWatch GenAI Observability dashboard
```

# Lab 6 Notes Takeaway
## Create Frontend/UI
* Chat interface allows customers to interact with the support agent
* Frontend connects to AgentCore Runtime endpoint deployed in Lab 4
* Streamlit application with UI and authentication - Amazon Cognito handles AgentCore Runtime requests
* Session id is generated per session and allows the agent to remember context and consumer preferences

Key components:
```
- main.py — main Streamlit app, handles auth and the chat loop
- chat.py — ChatManager class that invokes the AgentCore Runtime endpoint
- chat_utils.py — formatting helpers (clickable URLs, safe markdown)
- sagemaker_helper.py — generates an accessible URL for the app
```

```python
# Cognito auth in Streamlit
authenticator = CognitoAuthenticator(
    pool_id=secret["pool_id"], app_client_id=secret["client_id"],
    app_client_secret=secret["client_secret"],
)
if not authenticator.login():
    st.stop()

# Stream responses from AgentCore Runtime
response = requests.post(
    f"https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{escaped_arn}/invocations",
    headers={"Authorization": f"Bearer {token}", "X-Amzn-Bedrock-AgentCore-Runtime-Session-Id": session_id},
    json={"prompt": user_input}, stream=True,
)
for line in response.iter_lines(decode_unicode=True):
    if line.startswith("data: "):
        yield line[6:]
```
# Lab 7 - Cleanup
* See lab 7 for instructions on cleaning up dependencies
    * I have this downloaded for future reference

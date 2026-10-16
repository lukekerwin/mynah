"""Dictation prompts used for recordings.

READ prompts have an exact reference transcript, so they are scored by WER.
FREE prompts are spoken naturally (fillers, restarts, self-corrections) and are
used to judge the LLM cleanup step; their `intent` is what the final text should
convey, not a verbatim reference.
"""

READ = [
    # Email
    ("email-1", "email", "Hi Sarah, thanks for sending over the proposal. I had a chance to review it last night and I think the timeline looks reasonable, but I have a few questions about the budget section."),
    ("email-2", "email", "Just following up on our conversation from Tuesday. Could you send me the updated contract by the end of the week? Let me know if anything changes on your end."),
    ("email-3", "email", "I'm going to be out of the office from the twelfth through the nineteenth. If anything urgent comes up, please reach out to Michael directly."),
    # Chat
    ("chat-1", "chat", "sounds good, I'll grab coffee on the way and meet you there in like twenty minutes"),
    ("chat-2", "chat", "honestly I think we should just ship it and fix the edge cases next sprint"),
    ("chat-3", "chat", "did anyone else get the calendar invite for the offsite or was that just me"),
    # Technical / jargon
    ("tech-1", "tech", "Can you check whether the Postgres migration ran before the Kubernetes deployment rolled out? The API pods are throwing connection errors."),
    ("tech-2", "tech", "Let's refactor the useEffect hook so it doesn't refetch on every render, and move the fetch logic into a custom hook."),
    ("tech-3", "tech", "I pushed a fix to the main branch that bumps the TypeScript version and updates the ESLint config."),
    ("tech-4", "tech", "The Lambda function times out after thirty seconds because the S3 upload is synchronous. We should switch to a presigned URL."),
    # Names and proper nouns
    ("names-1", "names", "I spoke with Priya Raghunathan and Tomasz Kowalczyk from the Anthropic partnerships team yesterday."),
    ("names-2", "names", "We're flying from San Francisco to Reykjavik and then driving to Akureyri for the weekend."),
    # Numbers, dates, money
    ("numbers-1", "numbers", "The quarterly revenue came in at four point two million dollars, up eighteen percent from last year."),
    ("numbers-2", "numbers", "Let's schedule the call for three thirty PM on Thursday, October twenty third."),
    # Longer, rambling paragraph
    ("long-1", "long", "So the main thing I wanted to flag is that the onboarding flow is way too long. Most users drop off at the third screen, which is where we ask for their company size and role. I think we could defer those questions until after they've actually used the product for a day or two, and we'd probably see a pretty big jump in activation."),
    ("long-2", "long", "For the trip, I was thinking we leave Friday morning, stop for lunch somewhere around Sacramento, and get to the cabin by late afternoon. That way we have the whole evening to settle in, and we can start the hike early on Saturday before it gets too hot."),
    # Short commands / quick notes
    ("short-1", "short", "Remind me to call the dentist tomorrow."),
    ("short-2", "short", "Add milk, eggs, and spinach to the grocery list."),
    # Punctuation-heavy
    ("punct-1", "punct", "Wait, really? I thought the deadline was next Monday, not this Friday."),
    ("punct-2", "punct", "There are three options: we delay the launch, we cut scope, or we add another engineer."),
]

FREE = [
    ("free-1", "Tell a coworker you'll be late to a meeting. Change your mind about the time halfway through (e.g. say 2pm, then correct to 3pm).",
     "Let them know you'll be late to the meeting, giving the corrected time."),
    ("free-2", "Describe a bug you've hit recently to a teammate, as if in Slack. Ramble a bit, use 'um' and 'like' naturally.",
     "A clear Slack-style description of the bug."),
    ("free-3", "Dictate a short email declining an invitation politely. Restart a sentence at least once.",
     "A polite, concise decline email."),
    ("free-4", "List 4 or 5 things you need to do this week, spoken as a stream of thought.",
     "A clean to-do list."),
    ("free-5", "Explain to a friend how to get to your favorite restaurant. Include a 'no wait, actually' correction.",
     "Clear directions with the correction applied."),
]

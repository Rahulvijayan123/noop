import Foundation

/// Client-side safety layer around every coach exchange: input is screened before it reaches the
/// model, output is screened before it reaches the screen, and the system prompt carries the same
/// rules so the model refuses on its own first.
enum CoachSafety {

    struct InputResult {
        let blocked: Bool
        let refusal: String?
        static let pass = InputResult(blocked: false, refusal: nil)
    }

    struct OutputResult {
        let clean: Bool
        let text: String
    }

    enum Violation {
        case pedSteroid, extremeCaloricDeficit, selfHarm, medicalAuthority, eatingDisorder
        case dangerousSupplements, medicalDiagnosis, promptInjection, minorUnsafe

        var refusal: String {
            switch self {
            case .medicalDiagnosis:
                return "I'm your health assistant, not a doctor — I can't diagnose conditions, interpret symptoms, or recommend treatments. "
                    + "Pain, injuries, or health symptoms need a licensed healthcare provider who can properly assess you. "
                    + "I'm here to help with your training, recovery, and sleep once you're cleared."
            case .promptInjection:
                return "I'm Sana, your health assistant — I'm here to help with your charge, effort, sleep, training, and nutrition. "
                    + "Let's keep it about your goals. What would you like to work on?"
            case .pedSteroid:
                return "I can't provide advice on performance-enhancing drugs, steroids, or related substances. "
                    + "These carry serious health risks and legal implications. "
                    + "If you're curious about optimizing performance naturally, I'm happy to help with evidence-based training, sleep, and nutrition strategies. "
                    + "For anything pharmaceutical, please consult a licensed physician."
            case .extremeCaloricDeficit:
                return "I can't recommend extreme caloric restriction — it's counterproductive for training and can be harmful to your health. "
                    + "Sustainable fat loss typically works best at a moderate deficit (300–500 calories below maintenance). "
                    + "If you're struggling with your relationship with food, please consider speaking with a registered dietitian or your doctor."
            case .selfHarm:
                return "I'm not equipped to help with what you're going through, but I want you to know that support is available. "
                    + "Please reach out to the **988 Suicide & Crisis Lifeline** (call or text **988** in the US) "
                    + "or the **Crisis Text Line** (text **HOME** to **741741**). You deserve support from someone trained to help."
            case .medicalAuthority:
                return "I'm a coach, not a medical professional. I can't diagnose conditions, prescribe treatments, or provide medical advice. "
                    + "For health concerns, please consult a licensed healthcare provider. I'm here to help with your training and recovery goals."
            case .eatingDisorder:
                return "I hear you, and I want to be honest — what you're describing sounds like it could benefit from support beyond what a coach can offer. "
                    + "There's no shame in that. The **National Eating Disorders Association** helpline is available at **1-800-931-2237**, "
                    + "or you can text **NEDA** to **741741**. I'm here for your training whenever you're ready."
            case .minorUnsafe:
                return "Some training approaches aren't recommended for younger athletes. "
                    + "I'll focus on age-appropriate training that builds a strong foundation. "
                    + "For anything health-related, it's important to involve a parent or guardian and your doctor."
            case .dangerousSupplements:
                return "I can't recommend specific dosages or protocols for supplements that carry significant health risks. "
                    + "Some of these substances can cause serious harm, especially without medical supervision. "
                    + "If you're interested in safe supplementation, I'm happy to discuss evidence-based options. For anything beyond that, please consult a doctor."
            }
        }
    }

    // MARK: Screening

    /// A missing or invalid age is treated as under 18: every guardrail stays safe if a caller forgets to resolve it.
    static func isMinor(_ userAge: Int?) -> Bool {
        guard let userAge, userAge > 0 else { return true }
        return userAge < 18
    }

    static func screenInput(_ text: String, userAge: Int?) -> InputResult {
        let lowered = text.lowercased()
        let normalized = normalize(lowered)
        let checks: [(Violation, Bool)] = [
            (.promptInjection, matches(lowered, promptInjectionTerms)),
            (.promptInjection, matches(lowered, offTopicTerms)),
            (.medicalDiagnosis, matches(lowered, medicalDiagnosisTerms)),
            (.pedSteroid, matches(normalized, pedTerms) || normalized.range(of: #"\btren\b"#, options: .regularExpression) != nil),
            (.selfHarm, matches(normalized, selfHarmTerms)),
            (.eatingDisorder, matches(normalized, eatingDisorderTerms)),
            (.extremeCaloricDeficit, matches(lowered, deficitTerms) || statesDeficit(lowered)),
            (.dangerousSupplements, matches(normalized, dangerousSupplementTerms)),
            (.minorUnsafe, isMinor(userAge) && matches(normalized, minorUnsafeInputTerms)),
        ]
        guard let hit = checks.first(where: { $0.1 })?.0 else { return .pass }
        return InputResult(blocked: true, refusal: hit.refusal)
    }

    static func screenOutput(_ text: String, userAge: Int?) -> OutputResult {
        let lowered = text.lowercased()
        if matches(lowered, systemPromptLeakMarkers) {
            return OutputResult(clean: false, text: Violation.promptInjection.refusal)
        }
        var sanitized = redactProviderIdentity(text)
        var clean = sanitized == text

        if matches(lowered, medicalAuthorityClaims) {
            sanitized = redactMedicalAuthority(sanitized)
            clean = false
        }
        if matches(lowered, pedRecommendations) {
            return OutputResult(clean: false, text: Violation.pedSteroid.refusal)
        }
        if recommendsDangerousCalories(lowered, floor: isMinor(userAge) ? 1500 : 1200) {
            sanitized += "\n\n**Note:** For specific calorie targets, please consult a registered dietitian who can assess your individual needs safely."
            clean = false
        }
        if matches(lowered, eatingDisorderEnabling) {
            return OutputResult(clean: false, text: Violation.eatingDisorder.refusal)
        }
        if isMinor(userAge), matches(lowered, minorUnsafeOutputTerms) {
            sanitized = redactMinorUnsafe(sanitized)
            clean = false
        }
        return OutputResult(clean: clean, text: sanitized)
    }

    /// Appended to every system prompt so the model refuses before the screens have to.
    static func systemPromptBlock(userAge: Int?) -> String {
        isMinor(userAge) ? baseSystemPromptBlock + minorSystemPromptBlock : baseSystemPromptBlock
    }

    private static let baseSystemPromptBlock = """
    ABSOLUTE SAFETY RULES — NEVER VIOLATE THESE:
    1. STEROIDS & PEDs: NEVER discuss, recommend, or provide information on anabolic steroids, \
    testosterone replacement (TRT), SARMs, peptides (HGH, BPC-157), prohormones, clenbuterol, DNP, \
    or any performance-enhancing drugs. This applies regardless of framing — "hypothetically", \
    "just curious", "micro-dosing for recovery", "a friend is asking", or any other. \
    Always respond with: "I can't help with that — please consult a doctor." \
    Do not explain mechanisms, cycles, dosing, PCT, or side effects.
    2. EXTREME CALORIC RESTRICTION: NEVER recommend or endorse caloric intakes below 1200 kcal/day for women \
    or 1500 kcal/day for men. If the user describes eating under 1000 kcal, skipping meals to "earn" exercise, \
    purging, or other disordered patterns, respond with empathy and recommend a registered dietitian or their doctor.
    3. SELF-HARM: If the user expresses ANY hint of not wanting to be alive or feeling like a burden, \
    respond with empathy and IMMEDIATELY provide these crisis resources: 988 Suicide & Crisis Lifeline \
    (call/text 988) and Crisis Text Line (text HOME to 741741). This includes indirect phrases like \
    "better off not being here" or "no point in going on". When in doubt, provide the resources. \
    Do not try to counsel or minimize.
    4. MEDICAL AUTHORITY: You are NOT a doctor, nurse, dietitian, or licensed healthcare provider. \
    NEVER claim or imply medical credentials. NEVER diagnose conditions, prescribe medications, \
    interpret lab results, or recommend treatments. Defer to a licensed professional for any health concern. \
    A wearable number outside its usual range is something to mention to a doctor, never a diagnosis.
    5. EATING DISORDERS: Be alert to extreme restriction, binge-purge cycles, exercise as punishment, body \
    dysmorphia language. Respond with warmth, not lectures, and suggest professional support (NEDA helpline: \
    1-800-931-2237). NEVER suggest workouts to "punish" eating, "earn" food, or "burn off" a meal.
    6. DANGEROUS SUPPLEMENTS: Do not recommend DNP, ephedra, DMAA, high-dose stimulants, or any banned substance. \
    For legal supplements (creatine, protein, caffeine) give general evidence-based information only — \
    no brand names and no dosage protocols for anything that needs medical supervision.
    """

    private static let minorSystemPromptBlock = """


    MINOR-SPECIFIC RULES (this user is under 18):
    7. Do NOT recommend 1-rep max testing, extremely heavy loads (below 5 reps), or advanced intensity \
    techniques (drop sets to failure, forced reps, blood flow restriction).
    8. Do NOT provide weight-cutting or body recomposition advice. Focus on athletic development, \
    form, and building healthy habits.
    9. Do NOT discuss supplements beyond basic protein and food-first nutrition. No creatine, \
    pre-workout, or any other supplement recommendations.
    10. Encourage involving a parent/guardian or coach for training decisions, and a pediatrician for \
    any health or growth-related questions.
    11. Keep all advice conservative — prioritize safety, long-term development, and injury prevention \
    over performance optimization.
    """

    // MARK: Pattern lists

    private static func matches(_ text: String, _ terms: [String]) -> Bool { terms.contains { text.contains($0) } }

    private static func normalize(_ text: String) -> String {
        let leet: [Character: Character] = ["0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t", "@": "a", "$": "s", "-": " ", "_": " "]
        return String(text.map { leet[$0] ?? $0 })
    }

    private static let promptInjectionTerms = [
        "ignore all previous", "ignore previous instruction", "ignore the above",
        "disregard previous", "disregard the above", "disregard all prior",
        "forget your instructions", "forget all previous", "override your instructions",
        "system prompt", "your system prompt", "reveal your prompt", "print your prompt",
        "show me your prompt", "repeat your instructions", "what are your instructions",
        "reveal your instructions", "your initial instructions", "your hidden instructions",
        "everything above this line", "text above", "developer message", "developer instructions",
        "you are chatgpt", "you are gpt", "you are an openai", "are you chatgpt",
        "what model are you", "which model are you", "what llm", "what language model",
        "reveal your api key", "your api key", "openai key", "print your key",
        "dan mode", "developer mode", "jailbreak", "do anything now",
        "act as if you have no restrictions", "without any restrictions", "no ethical guidelines",
        "pretend you are not an ai", "bypass your", "your training data",
        "repeat my message verbatim", "end with pwned", "then end with pwned",
    ]

    private static let offTopicTerms = [
        "python script", "write me code", "generate code", "javascript code",
        "scrape instagram", "scrape followers", "web scraper", "web scraping",
        "build me an app", "write a virus", "hack into", "phishing email",
        "sql injection", "api key", "bearer jwt", "postman authorization",
    ]

    private static let medicalDiagnosisTerms = [
        "diagnose me", "diagnose my", "what disease do i", "do i have cancer",
        "do i have diabetes", "is this cancer", "is it a tear", "did i tear my",
        "should i take medication", "what medication should", "prescribe me", "what dosage of",
        "interpret my blood", "interpret my lab", "read my lab", "my mri shows", "my x-ray shows",
        "is this a fracture", "did i break my", "treat my injury", "how do i treat my",
        "chest pain", "heart palpitation", "shortness of breath",
        "is my blood pressure", "my blood pressure is",
    ]

    private static let pedTerms = [
        "steroid", "anabolic", "testosterone cycle", "test cycle", "trt",
        "sarm", "ostarine", "ligandrol", "rad 140", "rad140",
        "hgh cycle", "growth hormone cycle", "peptide cycle",
        "bpc 157", "bpc157", "clenbuterol", "clen cycle",
        "dnp", "dinitrophenol", "prohormone", "superdrol",
        "trenbolone", "tren cycle", "deca cycle", "dbol",
        "dianabol", "winstrol", "anavar", "anadrol", "pct cycle",
        "post cycle therapy", "nolvadex", "clomid cycle",
        "how to use steroids", "steroid stack", "steroid cycle",
        "best ped", "ped advice", "ped recommendation",
        "where to buy steroids", "how to get steroids",
        "inject testosterone", "testosterone injection",
        "mk 677", "mk677", "ibutamoren", "cardarine",
        "yk 11", "yk11", "lgd 4033", "lgd4033",
    ]

    private static let selfHarmTerms = [
        "kill myself", "want to die", "end my life", "end it all",
        "suicide", "suicidal", "self harm", "cut myself",
        "don't want to live", "dont want to live",
        "not worth living", "better off dead",
        "better off not being here", "better off without me",
        "don't want to be here anymore", "dont want to be here anymore",
        "not be here anymore", "wish i wasn't here",
        "rather be dead", "want to be dead",
        "hurt myself", "harm myself", "take my life",
        "no point in living", "what's the point of living",
        "everyone would be better off", "world would be better without me",
    ]

    private static let eatingDisorderTerms = [
        "make myself throw up", "make myself vomit", "purge after",
        "how to purge", "laxative for weight", "laxatives to lose",
        "anorexia tips", "pro ana", "pro mia",
        "thinspo", "thinspiration", "how to starve",
        "water fast for weeks", "7 day water fast", "14 day fast",
        "punish myself for eating", "punish myself in the gym", "punish myself",
        "earn food", "earn my food", "earn calories", "earn my calories",
        "exercise to earn", "workout to earn", "gym to earn",
        "i deserve to starve",
        "disgusted by my body", "hate my body so much",
        "need to stop eating", "afraid to eat",
        "hide binge", "hide my binge", "hide purging",
    ]

    private static let deficitTerms = [
        "500 calorie diet", "600 calorie diet", "700 calorie diet",
        "800 calorie diet", "200 calorie", "300 calorie day",
        "eat nothing", "stop eating completely",
        "zero calorie diet", "snake diet", "dry fast",
        "500 kcal per day", "600 kcal per day", "700 kcal per day",
        "800 kcal per day", "500 kcal/day", "600 kcal/day", "800 kcal/day",
    ]

    private static let minorUnsafeInputTerms = [
        "weight cut", "cutting weight for", "make weight",
        "water cut", "sauna suit to cut", "how to cut weight fast",
        "best pre workout", "pre workout supplement",
        "creatine dose", "creatine loading", "how much creatine",
        "testosterone boost", "test booster",
        "fat burner supplement", "thermogenic",
    ]

    private static let minorUnsafeOutputTerms = [
        "test your one rep max", "test your 1rm", "find your 1rm",
        "go to failure on every set", "train to absolute failure",
        "blood flow restriction", "bfr training",
        "take creatine", "creatine supplement", "pre-workout supplement",
        "start cutting at", "caloric deficit of",
    ]

    private static let dangerousSupplementTerms = [
        "dnp dosage", "dnp cycle", "dinitrophenol dose",
        "ephedra dose", "ephedra stack", "eca stack dose",
        "dmaa dose", "dmaa supplement", "how much dmaa",
        "insulin for bodybuilding", "inject insulin",
        "synthol", "site enhancement",
    ]

    /// "eating 600 kcal/day" style statements below the floor.
    private static func statesDeficit(_ text: String) -> Bool {
        caloriesPerDay(in: text, pattern: #"\b([2-9]\d{2}|1[01]\d{2})\s*(?:kcal|cal(?:orie)?s?)\s*(?:/\s*day|per\s+day|a\s+day)\b"#)
            .contains { $0 < 1200 }
    }

    private static func caloriesPerDay(in text: String, pattern: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    // MARK: Output patterns

    private static let systemPromptLeakMarkers = [
        "absolute safety rules", "never violate these", "remembered context (from previous",
        "do not say \"based on the data provided\"", "here is my system prompt",
        "my system prompt is", "my instructions are:", "my initial instructions",
        "context library (queryable", "earlier in this conversation (summary",
    ]

    private static let medicalAuthorityClaims = [
        "as a doctor", "as a physician", "as a medical professional",
        "i am a doctor", "i am a physician", "i'm a doctor",
        "i'm a physician", "in my medical opinion",
        "i can diagnose", "my diagnosis is", "i diagnose",
        "based on your symptoms, you have",
        "you are suffering from", "you likely have",
        "i prescribe", "you should take this medication",
        "as a licensed", "as a certified medical",
        "as your healthcare provider",
    ]

    private static let pedRecommendations = [
        "recommended steroid", "recommended cycle",
        "start with testosterone", "beginner steroid cycle",
        "mg per week of test", "ml of testosterone",
        "inject into your", "run a cycle of",
        "stack with deca", "pct after your cycle",
        "dose of tren", "dose of dianabol",
    ]

    private static let eatingDisorderEnabling = [
        "punish yourself", "punish yourself in the gym", "punish yourself for eating",
        "earn your food", "earn food back", "earn those calories", "earn your calories",
        "burn off what you ate", "burn off the meal", "work off what you ate",
        "cardio to make up for eating", "exercise as punishment",
        "extra cardio because you ate", "make up for eating",
    ]

    private static func recommendsDangerousCalories(_ lowered: String, floor: Int) -> Bool {
        guard let re = try? NSRegularExpression(pattern: #"(\d{3,4})\s*(?:cal(?:orie)?s?|kcal)\s*(?:per\s*day|daily|a\s*day)"#) else { return false }
        let context = ["recommend", "suggest", "try", "aim for", "eat", "consume", "target"]
        for match in re.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
            guard let numRange = Range(match.range(at: 1), in: lowered), let kcal = Int(lowered[numRange]), kcal < floor else { continue }
            let start = lowered.index(numRange.lowerBound, offsetBy: -80, limitedBy: lowered.startIndex) ?? lowered.startIndex
            let end = lowered.index(numRange.upperBound, offsetBy: 40, limitedBy: lowered.endIndex) ?? lowered.endIndex
            if context.contains(where: { lowered[start..<end].contains($0) }) { return true }
        }
        return false
    }

    private static func redactProviderIdentity(_ text: String) -> String {
        let swaps: [(String, String)] = [
            ("OpenAI", "your coach"), ("ChatGPT", "your coach"),
            ("GPT-4", "your coach"), ("GPT-5", "your coach"),
            ("Anthropic", "your coach"), ("Claude", "your coach"),
            ("a large language model", "your coach"),
            ("as an AI language model", "as your coach"),
            ("as a language model", "as your coach"),
        ]
        return swaps.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .caseInsensitive) }
    }

    private static func redactMinorUnsafe(_ text: String) -> String {
        let swaps: [(String, String)] = [
            ("test your one rep max", "build strength gradually with sets of 5-8 reps"),
            ("test your 1RM", "build strength gradually with sets of 5-8 reps"),
            ("find your 1RM", "build strength gradually with sets of 5-8 reps"),
            ("go to failure on every set", "leave 2-3 reps in reserve on each set"),
            ("train to absolute failure", "train with 2-3 reps in reserve"),
        ]
        let redacted = swaps.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1, options: .caseInsensitive) }
        return redacted + "\n\n**Reminder:** For athletes under 18, always involve a coach or parent in training decisions."
    }

    private static func redactMedicalAuthority(_ text: String) -> String {
        let swaps: [(String, String)] = [
            ("As a doctor", "As your coach"), ("As a physician", "As your coach"),
            ("As a medical professional", "As your coach"),
            ("as a doctor", "as your coach"), ("as a physician", "as your coach"),
            ("as a medical professional", "as your coach"),
            ("In my medical opinion", "From a training perspective"),
            ("in my medical opinion", "from a training perspective"),
            ("I can diagnose", "I can't diagnose — please see a doctor. I can"),
            ("My diagnosis is", "I'm not qualified to diagnose. Please see a doctor. My observation is"),
        ]
        return swaps.reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

// MARK: - PII scrubbing

/// Regex redaction of personal identifiers in what the user types, applied before the text is
/// shown, stored, or sent. Heuristic by design: it catches the common shapes, not every possible one.
enum CoachPIIScrubber {
    struct Result: Equatable {
        let text: String
        let redactions: Int
    }

    private static let rules: [(NSRegularExpression, String)] = {
        let defs: [(String, String)] = [
            (#"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#, "[EMAIL]"),
            (#"(\+?1[\s\-.]?)?\(?\d{3}\)?[\s\-.]?\d{3}[\s\-.]?\d{4}"#, "[PHONE]"),
            (#"\b\d{3}[\s\-]\d{2}[\s\-]\d{4}\b"#, "[SSN]"),
            (#"(?i)\b(mrn|patient\s?id|chart\s*#?)\s*[:\-]?\s*[a-zA-Z0-9]{4,12}\b"#, "[ID]"),
            (#"(?i)(d\.?o\.?b\.?|date\s+of\s+birth|born\s+on)\s*[:\-]?\s*\d{1,2}[/\-\.]\d{1,2}[/\-\.]\d{2,4}"#, "[DATE_OF_BIRTH]"),
            // The phrase is case-insensitive but the name itself must be capitalised; a blanket (?i)
            // would turn "I'm tired" into "I'm [NAME]".
            (#"((?i:my name is|i'm|i am|call me))\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?"#, "$1 [NAME]"),
            (#"((?i:\b(?:dr|mrs?|ms)\.?))\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?"#, "$1 [NAME]"),
            (#"(?i)\b(zip|postal\s+code)\s*[:\-]?\s*\d{5}(?:[\-]\d{4})?\b"#, "[ZIP]"),
            (#"\b\d{1,5}\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\s+(St|Ave|Blvd|Rd|Dr|Ct|Ln|Way|Pl)\.?\b"#, "[ADDRESS]"),
        ]
        return defs.compactMap { pattern, template in (try? NSRegularExpression(pattern: pattern)).map { ($0, template) } }
    }()

    static func scrub(_ text: String) -> Result {
        var result = text
        var total = 0
        for (rule, template) in rules {
            let hits = rule.numberOfMatches(in: result, range: NSRange(result.startIndex..., in: result))
            guard hits > 0 else { continue }
            total += hits
            result = rule.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: template)
        }
        return Result(text: result, redactions: total)
    }
}

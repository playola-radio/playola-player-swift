# PlayolaPlayer Guidelines

## Build & Test Commands
- Build package: `swift build`
- Run all tests: `swift test`
- Run specific test: `swift test --filter PlayolaPlayerTests/testName`
- Run specific test suite: `swift test --filter AudioNormalizationCalculatorTests`
- Generate Xcode project: `swift package generate-xcodeproj`

## Code Style Guidelines
- Follow Swift API Design Guidelines
- Use Swift Concurrency (async/await) for asynchronous operations
- Document all public APIs with standard documentation comments
- Maintain proper actor isolation for thread safety

## Naming Conventions
- Types: UpperCamelCase (AudioBlock, PlayolaStationPlayer)
- Properties/methods: lowerCamelCase
- Constants: lowerCamelCase
- Acronyms: capitalize all letters in acronyms (e.g., URL, JSON)

## Error Handling
- Use PlayolaErrorReporter for consistent error reporting
- Use proper async/await error handling with do/catch
- Provide meaningful error contexts

## Type Usage
- Model types should conform to Codable, Sendable, Equatable & Hashable
- Use strong typing and avoid optionals where possible
- Use proper access control (public, internal, private)
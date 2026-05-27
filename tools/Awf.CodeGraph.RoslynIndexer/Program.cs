using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Build.Locator;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;
using Microsoft.CodeAnalysis.MSBuild;

static string GetArg(string[] args, string name)
{
    var index = Array.IndexOf(args, name);
    if (index < 0 || index + 1 >= args.Length)
    {
        throw new ArgumentException($"Missing required argument '{name}'.");
    }

    return args[index + 1];
}

static string? TryGetArg(string[] args, string name)
{
    var index = Array.IndexOf(args, name);
    if (index < 0)
    {
        return null;
    }

    if (index + 1 >= args.Length)
    {
        throw new ArgumentException($"Missing required argument '{name}'.");
    }

    return args[index + 1];
}

static string NormalizePath(string path) => path.Replace('\\', '/');

static string GetRelativePath(string rootPath, string path) =>
    NormalizePath(Path.GetRelativePath(rootPath, path));

static string GetFileKind(string relativePath)
{
    return relativePath.Contains("/test/", StringComparison.OrdinalIgnoreCase) ||
           relativePath.Contains("/tests/", StringComparison.OrdinalIgnoreCase) ||
           relativePath.EndsWith("Tests.cs", StringComparison.OrdinalIgnoreCase)
        ? "test"
        : "source";
}

static bool IsTestProject(Project project)
{
    return project.Name.EndsWith("Test", StringComparison.OrdinalIgnoreCase) ||
           project.Name.EndsWith("Tests", StringComparison.OrdinalIgnoreCase);
}

static bool IsNamedType(INamedTypeSymbol? typeSymbol, string namespaceName, string typeName)
{
    return typeSymbol is not null &&
           typeSymbol.Name == typeName &&
           typeSymbol.ContainingNamespace.ToDisplayString() == namespaceName;
}

static bool InheritsFrom(INamedTypeSymbol? typeSymbol, string namespaceName, string typeName)
{
    for (var current = typeSymbol; current is not null; current = current.BaseType)
    {
        if (IsNamedType(current, namespaceName, typeName))
        {
            return true;
        }
    }

    return false;
}

static bool ImplementsInterface(INamedTypeSymbol? typeSymbol, string namespaceName, string typeName)
{
    return typeSymbol is not null &&
           typeSymbol.AllInterfaces.Any(interfaceSymbol => IsNamedType(interfaceSymbol, namespaceName, typeName));
}

static bool HasAttribute(INamedTypeSymbol? typeSymbol, string namespaceName, string typeName)
{
    return typeSymbol is not null &&
           typeSymbol.GetAttributes().Any(attribute =>
               IsNamedType(attribute.AttributeClass, namespaceName, typeName));
}

static bool HasPublicOrdinaryMethod(INamedTypeSymbol? typeSymbol, string methodName)
{
    return typeSymbol is not null &&
           typeSymbol.GetMembers(methodName)
               .OfType<IMethodSymbol>()
               .Any(method => method.MethodKind == MethodKind.Ordinary &&
                              method.DeclaredAccessibility == Accessibility.Public);
}

static bool IsDataCarrier(INamedTypeSymbol? typeSymbol)
{
    if (typeSymbol is null)
    {
        return false;
    }

    return !typeSymbol.GetMembers().OfType<IMethodSymbol>().Any(method =>
        method.MethodKind == MethodKind.Ordinary &&
        method.DeclaredAccessibility == Accessibility.Public);
}

static string GetFrameworkKind(INamedTypeSymbol? typeSymbol, string relativePath, string declaredName)
{
    if (typeSymbol is null)
    {
        return GetFileKind(relativePath);
    }

    if (HasAttribute(typeSymbol, "Microsoft.AspNetCore.Mvc", "ApiControllerAttribute") ||
        InheritsFrom(typeSymbol, "Microsoft.AspNetCore.Mvc", "ControllerBase"))
    {
        return "api-controller";
    }

    if ((declaredName.EndsWith("Dto", StringComparison.OrdinalIgnoreCase) ||
         declaredName.EndsWith("Request", StringComparison.OrdinalIgnoreCase) ||
         declaredName.EndsWith("Response", StringComparison.OrdinalIgnoreCase)) &&
        IsDataCarrier(typeSymbol))
    {
        return "dto";
    }

    if (InheritsFrom(typeSymbol, "FluentValidation", "AbstractValidator"))
    {
        return "validator";
    }

    if (declaredName.EndsWith("Middleware", StringComparison.OrdinalIgnoreCase) &&
        HasPublicOrdinaryMethod(typeSymbol, "InvokeAsync"))
    {
        return "middleware";
    }

    if (InheritsFrom(typeSymbol, "Microsoft.EntityFrameworkCore", "DbContext"))
    {
        return "ef-dbcontext";
    }

    if (declaredName.EndsWith("Entity", StringComparison.OrdinalIgnoreCase) ||
        relativePath.Contains("/entities/", StringComparison.OrdinalIgnoreCase))
    {
        return "ef-entity";
    }

    if (ImplementsInterface(typeSymbol, "MediatR", "IRequestHandler"))
    {
        return "mediatr-handler";
    }

    if (typeSymbol.TypeKind == TypeKind.Class &&
        typeSymbol.IsStatic &&
        declaredName.EndsWith("Extensions", StringComparison.OrdinalIgnoreCase) &&
        typeSymbol.GetMembers().OfType<IMethodSymbol>().Any(method =>
            method.MethodKind == MethodKind.Ordinary &&
            method.IsStatic &&
            method.Parameters.Any(parameter =>
                parameter.Type.Name == "IServiceCollection" &&
                parameter.Type.ContainingNamespace.ToDisplayString() == "Microsoft.Extensions.DependencyInjection")))
    {
        return "di-registration";
    }

    return "source";
}

static string GetSymbolKind(ISymbol symbol) => symbol switch
{
    INamedTypeSymbol namedType => namedType.TypeKind switch
    {
        TypeKind.Class => "class",
        TypeKind.Interface => "interface",
        TypeKind.Struct => "struct",
        TypeKind.Enum => "enum",
        TypeKind.Delegate => "delegate",
        _ => "type"
    },
    IMethodSymbol method when method.MethodKind == MethodKind.Constructor => "constructor",
    IMethodSymbol => "method",
    IPropertySymbol => "property",
    IFieldSymbol => "field",
    IEventSymbol => "event",
    _ => symbol.Kind.ToString().ToLowerInvariant()
};

static string GetId(string relativePath, string symbolDisplay) =>
    $"symbol:{relativePath}#{symbolDisplay}";

static bool TryGetTargetId(ISymbol symbol, string repoPath, out string targetId)
{
    targetId = string.Empty;

    var targetSymbol = symbol switch
    {
        ITypeSymbol typeSymbol => typeSymbol.OriginalDefinition,
        IMethodSymbol methodSymbol => methodSymbol.OriginalDefinition,
        IPropertySymbol propertySymbol => propertySymbol.OriginalDefinition,
        IFieldSymbol fieldSymbol => fieldSymbol.OriginalDefinition,
        IEventSymbol eventSymbol => eventSymbol.OriginalDefinition,
        _ => symbol
    };

    var sourceLocation = targetSymbol.Locations
        .Where(location => location is not null && location.IsInSource && location.SourceTree?.FilePath is not null)
        .OrderBy(location => location!.SourceTree!.FilePath, StringComparer.OrdinalIgnoreCase)
        .ThenBy(location => location!.GetLineSpan().StartLinePosition.Line)
        .ThenBy(location => location!.GetLineSpan().StartLinePosition.Character)
        .FirstOrDefault();

    if (sourceLocation?.SourceTree?.FilePath is string sourcePath)
    {
        var relativePath = GetRelativePath(repoPath, sourcePath);
        if (relativePath.Contains("/obj/", StringComparison.OrdinalIgnoreCase) ||
            relativePath.Contains("/bin/", StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }

        var displayName = targetSymbol.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat);
        targetId = GetId(relativePath, displayName);
        return true;
    }

    return false;
}

static void AddSemanticEdge(List<object> edges, string from, ISymbol target, string relationType, string repoPath)
{
    if (!TryGetTargetId(target, repoPath, out var targetId))
    {
        return;
    }

    edges.Add(new
    {
        from,
        to = targetId,
        type = relationType,
        confidence = "high",
        source = "roslyn"
    });
}

static IEnumerable<ISymbol> GetSemanticTargetSymbols(ITypeSymbol typeSymbol)
{
    if (typeSymbol is IArrayTypeSymbol arrayTypeSymbol)
    {
        foreach (var target in GetSemanticTargetSymbols(arrayTypeSymbol.ElementType))
        {
            yield return target;
        }

        yield break;
    }

    if (typeSymbol is INamedTypeSymbol namedTypeSymbol)
    {
        if (namedTypeSymbol.SpecialType == SpecialType.System_Nullable_T && namedTypeSymbol.TypeArguments.Length == 1)
        {
            foreach (var target in GetSemanticTargetSymbols(namedTypeSymbol.TypeArguments[0]))
            {
                yield return target;
            }

            yield break;
        }

        if (namedTypeSymbol.IsTupleType)
        {
            foreach (var element in namedTypeSymbol.TupleElements)
            {
                foreach (var target in GetSemanticTargetSymbols(element.Type))
                {
                    yield return target;
                }
            }

            yield break;
        }

        foreach (var typeArgument in namedTypeSymbol.TypeArguments)
        {
            foreach (var target in GetSemanticTargetSymbols(typeArgument))
            {
                yield return target;
            }
        }
    }

    yield return typeSymbol;
}

static int GetStartLine(SyntaxNode node) =>
    node.SyntaxTree.GetLineSpan(node.Span).StartLinePosition.Line + 1;

static int GetEndLine(SyntaxNode node) =>
    node.SyntaxTree.GetLineSpan(node.Span).EndLinePosition.Line + 1;

static string GetHash(string path)
{
    using var stream = File.OpenRead(path);
    using var sha = SHA256.Create();
    return Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant();
}

static string ToJson(object value) => JsonSerializer.Serialize(value);

static string? FindDotnetSdkMsBuildPath()
{
    var sdkRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        "dotnet",
        "sdk");

    if (!Directory.Exists(sdkRoot))
    {
        return null;
    }

    var candidate = Directory
        .EnumerateDirectories(sdkRoot)
        .OrderByDescending(path => path, StringComparer.OrdinalIgnoreCase)
        .FirstOrDefault(path => File.Exists(Path.Combine(path, "MSBuild.dll")));

    return candidate;
}

static void RegisterMsBuild()
{
    if (MSBuildLocator.IsRegistered)
    {
        return;
    }

    try
    {
        MSBuildLocator.RegisterDefaults();
    }
    catch (InvalidOperationException)
    {
        var sdkPath = FindDotnetSdkMsBuildPath();
        if (sdkPath is null)
        {
            throw;
        }

        MSBuildLocator.RegisterMSBuildPath(sdkPath);
    }
}

var repoPath = Path.GetFullPath(GetArg(args, "--repo"));
var solutionPath = TryGetArg(args, "--solution");
var projectPath = TryGetArg(args, "--project");
var outputPath = Path.GetFullPath(GetArg(args, "--output"));

if (string.IsNullOrWhiteSpace(solutionPath) == string.IsNullOrWhiteSpace(projectPath))
{
    throw new ArgumentException("Specify exactly one of --solution or --project.");
}

if (solutionPath is not null)
{
    solutionPath = Path.GetFullPath(solutionPath);
}

if (projectPath is not null)
{
    projectPath = Path.GetFullPath(projectPath);
}

RegisterMsBuild();
using var workspace = MSBuildWorkspace.Create();
var solution = solutionPath is not null
    ? await workspace.OpenSolutionAsync(solutionPath)
    : (await workspace.OpenProjectAsync(projectPath!)).Solution;

Directory.CreateDirectory(outputPath);

var files = new List<object>();
var symbols = new List<object>();
var edges = new List<object>();
var summaries = new List<object>();
var generatedUtc = DateTime.UtcNow.ToString("o");

foreach (var project in solution.Projects.Where(project => project.Language == LanguageNames.CSharp))
{
    foreach (var document in project.Documents.Where(document => document.FilePath is not null))
    {
        var filePath = document.FilePath!;
        var relativePath = GetRelativePath(repoPath, filePath);
        if (relativePath.Contains("/obj/", StringComparison.OrdinalIgnoreCase) ||
            relativePath.Contains("/bin/", StringComparison.OrdinalIgnoreCase))
        {
            continue;
        }

        var sourceText = await document.GetTextAsync();
        var syntaxTree = await document.GetSyntaxTreeAsync();
        if (syntaxTree is null)
        {
            continue;
        }

        var root = await syntaxTree.GetRootAsync();
        var semanticModel = await document.GetSemanticModelAsync();
        if (semanticModel is null)
        {
            continue;
        }

        var typeSymbols = root.DescendantNodes()
            .OfType<TypeDeclarationSyntax>()
            .Select(typeNode => semanticModel.GetDeclaredSymbol(typeNode))
            .OfType<INamedTypeSymbol>()
            .ToList();

        var kind = IsTestProject(project)
            ? "test"
            : GetFileKind(relativePath);

        if (kind != "test")
        {
            foreach (var typeSymbol in typeSymbols)
            {
                var frameworkKind = GetFrameworkKind(typeSymbol, relativePath, typeSymbol.Name);
                if (frameworkKind != "source")
                {
                    kind = frameworkKind;
                    break;
                }
            }
        }

        var hash = GetHash(filePath);

        files.Add(new
        {
            id = $"file:{relativePath}",
            path = relativePath,
            language = "csharp",
            kind,
            hash,
            lineCount = sourceText.Lines.Count,
            source = "roslyn",
            confidence = "high",
            indexedUtc = generatedUtc
        });

        var symbolNames = new List<string>();
        var declaredSymbols = new List<object>();
        var declaredEdges = new List<object>();

        foreach (var node in root.DescendantNodes())
        {
            if (node is not MemberDeclarationSyntax and not NamespaceDeclarationSyntax and not FileScopedNamespaceDeclarationSyntax)
            {
                continue;
            }

            var declaredSymbol = semanticModel.GetDeclaredSymbol(node);
            if (declaredSymbol is null)
            {
                continue;
            }

            if (declaredSymbol is not INamedTypeSymbol &&
                declaredSymbol is not IMethodSymbol &&
                declaredSymbol is not IPropertySymbol)
            {
                continue;
            }

            var displayName = declaredSymbol.ToDisplayString(SymbolDisplayFormat.CSharpErrorMessageFormat);
            var symbolKind = GetSymbolKind(declaredSymbol);
            var symbolName = declaredSymbol.Name;
            symbolNames.Add(symbolName);

            var container = declaredSymbol.ContainingType?.Name ?? declaredSymbol.ContainingNamespace?.ToDisplayString();
            var signature = declaredSymbol.ToDisplayString(SymbolDisplayFormat.MinimallyQualifiedFormat);
            var id = GetId(relativePath, displayName);

            declaredSymbols.Add(new
            {
                id,
                type = symbolKind,
                kind = symbolKind,
                name = symbolName,
                container,
                file = relativePath,
                language = "csharp",
                startLine = GetStartLine(node),
                endLine = GetEndLine(node),
                signature,
                hash,
                source = "roslyn",
                confidence = "high",
                indexedUtc = generatedUtc
            });

            declaredEdges.Add(new
            {
                from = $"file:{relativePath}",
                to = id,
                type = "defines",
                confidence = "high",
                source = "roslyn"
            });
        }

        foreach (var typeNode in root.DescendantNodes().OfType<TypeDeclarationSyntax>())
        {
            if (semanticModel.GetDeclaredSymbol(typeNode) is not INamedTypeSymbol namedType)
            {
                continue;
            }

            if (typeNode.BaseList is not null)
            {
                foreach (var baseTypeSyntax in typeNode.BaseList.Types)
                {
                    var baseTypeInfo = semanticModel.GetTypeInfo(baseTypeSyntax.Type);
                    if (baseTypeInfo.Type is not INamedTypeSymbol baseTypeSymbol)
                    {
                        continue;
                    }

                    if (baseTypeSymbol.TypeKind == TypeKind.Interface)
                    {
                        var relationType = namedType.TypeKind == TypeKind.Interface ? "inherits" : "implements";
                        AddSemanticEdge(declaredEdges, $"file:{relativePath}", baseTypeSymbol, relationType, repoPath);
                    }
                    else if (baseTypeSymbol.SpecialType != SpecialType.System_Object && namedType.TypeKind != TypeKind.Interface)
                    {
                        AddSemanticEdge(declaredEdges, $"file:{relativePath}", baseTypeSymbol, "inherits", repoPath);
                    }
                }
            }
        }

        foreach (var methodNode in root.DescendantNodes().OfType<BaseMethodDeclarationSyntax>())
        {
            if (semanticModel.GetDeclaredSymbol(methodNode) is not IMethodSymbol methodSymbol)
            {
                continue;
            }

            foreach (var parameter in methodSymbol.Parameters)
            {
                if (parameter.Type is not null)
                {
                    var targetIds = new HashSet<string>(StringComparer.Ordinal);
                    foreach (var semanticTarget in GetSemanticTargetSymbols(parameter.Type))
                    {
                        if (TryGetTargetId(semanticTarget, repoPath, out var targetId) && targetIds.Add(targetId))
                        {
                            declaredEdges.Add(new
                            {
                                from = $"file:{relativePath}",
                                to = targetId,
                                type = "parameter-types",
                                confidence = "high",
                                source = "roslyn"
                            });
                        }
                    }
                }
            }

            if (!methodSymbol.ReturnsVoid && methodSymbol.ReturnType is not null)
            {
                var targetIds = new HashSet<string>(StringComparer.Ordinal);
                foreach (var semanticTarget in GetSemanticTargetSymbols(methodSymbol.ReturnType))
                {
                    if (TryGetTargetId(semanticTarget, repoPath, out var targetId) && targetIds.Add(targetId))
                    {
                        declaredEdges.Add(new
                        {
                            from = $"file:{relativePath}",
                            to = targetId,
                            type = "returns",
                            confidence = "high",
                            source = "roslyn"
                        });
                    }
                }
            }

            var bodyNodes = methodNode.Body?.DescendantNodes().Cast<SyntaxNode>() ?? Enumerable.Empty<SyntaxNode>();
            if (methodNode.ExpressionBody is not null)
            {
                bodyNodes = bodyNodes.Concat(methodNode.ExpressionBody.Expression.DescendantNodesAndSelf().Cast<SyntaxNode>());
            }

            var referencedTargetIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var typeSyntax in bodyNodes.OfType<TypeSyntax>())
            {
                var typeInfo = semanticModel.GetTypeInfo(typeSyntax);
                if (typeInfo.Type is not null &&
                    typeInfo.Type is not IErrorTypeSymbol &&
                    TryGetTargetId(typeInfo.Type, repoPath, out var targetId) &&
                    referencedTargetIds.Add(targetId))
                {
                    declaredEdges.Add(new
                    {
                        from = $"file:{relativePath}",
                        to = targetId,
                        type = "references",
                        confidence = "high",
                        source = "roslyn"
                    });
                }
            }

            foreach (var syntaxNode in bodyNodes.Where(node =>
                         node is IdentifierNameSyntax or GenericNameSyntax or QualifiedNameSyntax))
            {
                var symbolInfo = semanticModel.GetSymbolInfo(syntaxNode);
                var referencedSymbol = symbolInfo.Symbol;
                if (referencedSymbol is ITypeSymbol referencedType &&
                    referencedType is not IErrorTypeSymbol &&
                    TryGetTargetId(referencedType, repoPath, out var targetId) &&
                    referencedTargetIds.Add(targetId))
                {
                    declaredEdges.Add(new
                    {
                        from = $"file:{relativePath}",
                        to = targetId,
                        type = "references",
                        confidence = "high",
                        source = "roslyn"
                    });
                }
            }

            foreach (var invocation in methodNode.DescendantNodes().OfType<InvocationExpressionSyntax>())
            {
                var invokedSymbolInfo = semanticModel.GetSymbolInfo(invocation);
                var invokedSymbol = invokedSymbolInfo.Symbol;

                if (invokedSymbol is not null)
                {
                    AddSemanticEdge(declaredEdges, $"file:{relativePath}", invokedSymbol, "invokes", repoPath);
                }
            }

            foreach (var objectCreation in methodNode.DescendantNodes().OfType<ObjectCreationExpressionSyntax>())
            {
                var constructorInfo = semanticModel.GetSymbolInfo(objectCreation);
                if (constructorInfo.Symbol is IMethodSymbol constructorSymbol)
                {
                    AddSemanticEdge(declaredEdges, $"file:{relativePath}", constructorSymbol, "invokes", repoPath);
                }
            }

            foreach (var implicitObjectCreation in methodNode.DescendantNodes().OfType<ImplicitObjectCreationExpressionSyntax>())
            {
                var constructorInfo = semanticModel.GetSymbolInfo(implicitObjectCreation);
                if (constructorInfo.Symbol is IMethodSymbol constructorSymbol)
                {
                    AddSemanticEdge(declaredEdges, $"file:{relativePath}", constructorSymbol, "invokes", repoPath);
                }
            }
        }

        symbols.AddRange(declaredSymbols);
        edges.AddRange(declaredEdges);

        summaries.Add(new
        {
            file = relativePath,
            language = "csharp",
            kind,
            summary = symbolNames.Count == 0
                ? "Contains source code."
                : $"Contains {kind} code. Key symbols: {string.Join(", ", symbolNames.Distinct(StringComparer.Ordinal))}.",
            generatedBy = "roslyn",
            generatedUtc,
            source = "roslyn",
            confidence = "high",
            indexedUtc = generatedUtc
        });
    }
}

await File.WriteAllLinesAsync(Path.Combine(outputPath, "files.jsonl"), files.Select(ToJson), Encoding.UTF8);
await File.WriteAllLinesAsync(Path.Combine(outputPath, "symbols.jsonl"), symbols.Select(ToJson), Encoding.UTF8);
await File.WriteAllLinesAsync(Path.Combine(outputPath, "edges.jsonl"), edges.Select(ToJson), Encoding.UTF8);
await File.WriteAllLinesAsync(Path.Combine(outputPath, "summaries.jsonl"), summaries.Select(ToJson), Encoding.UTF8);

var graphState = new
{
    version = "0.1.0",
    createdUtc = generatedUtc,
    lastUpdatedUtc = generatedUtc,
    indexer = "roslyn",
    indexedFileCount = files.Count
};

await File.WriteAllTextAsync(
    Path.Combine(outputPath, "graph-state.json"),
    JsonSerializer.Serialize(graphState, new JsonSerializerOptions { WriteIndented = true }),
    Encoding.UTF8);

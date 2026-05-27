using RoslynFrameworkSample;

namespace RoslynFrameworkSample.Tests;

public sealed class Support
{
    public ProductionService CreateService() => new();
}

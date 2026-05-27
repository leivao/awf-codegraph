using Xunit;

namespace RoslynFrameworkSample.Tests;

public sealed class TestService
{
    [Fact]
    public void UsesProductionService()
    {
        var service = new ProductionService();
        Assert.NotNull(service);
    }
}

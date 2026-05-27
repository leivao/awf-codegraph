using MediatR;

namespace RoslynFrameworkSample;

public sealed class CreateThingRequest : IRequest<CreateThingResponse>
{
    public string Name { get; init; } = string.Empty;
}

public sealed class CreateThingResponse
{
    public int Id { get; init; }
}

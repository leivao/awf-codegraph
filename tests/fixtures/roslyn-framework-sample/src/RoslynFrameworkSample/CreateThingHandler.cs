using MediatR;

namespace RoslynFrameworkSample;

public sealed class CreateThingHandler : IRequestHandler<CreateThingRequest, CreateThingResponse>
{
    public Task<CreateThingResponse> Handle(CreateThingRequest request, CancellationToken cancellationToken)
    {
        return Task.FromResult(new CreateThingResponse { Id = request.Name.Length });
    }
}

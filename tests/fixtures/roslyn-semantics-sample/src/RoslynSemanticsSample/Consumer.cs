namespace RoslynSemanticsSample;

public sealed class Consumer
{
    public string Run(IService service)
    {
        var localService = new Service();
        var label = Service.Label;
        return localService.Execute(service.Execute("ping") + label);
    }

    public Service CreateService()
    {
        return new Service();
    }

    public Task<Service> CreateServiceAsync()
    {
        return Task.FromResult(new Service());
    }

    public Service UseWrapped(Task<Service> serviceTask)
    {
        return serviceTask.Result;
    }
}

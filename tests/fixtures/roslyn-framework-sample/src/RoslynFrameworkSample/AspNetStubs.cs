namespace Microsoft.AspNetCore.Mvc;

[AttributeUsage(AttributeTargets.Class, AllowMultiple = false)]
public sealed class ApiControllerAttribute : Attribute
{
}

[AttributeUsage(AttributeTargets.Class, AllowMultiple = false)]
public sealed class RouteAttribute : Attribute
{
    public RouteAttribute(string template)
    {
        Template = template;
    }

    public string Template { get; }
}

public abstract class ControllerBase
{
}

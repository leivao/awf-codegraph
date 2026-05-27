namespace RoslynSemanticsSample;

public interface IService
{
    string Execute(string input);
}

public interface IChild : IService
{
}

public abstract class BaseService
{
    public virtual string Format(string value) => value;
}

public sealed class Service : BaseService, IService
{
    public static string Label => "service";

    public override string Format(string value) => value.ToUpperInvariant();
    public string Execute(string input) => Format(input);
}

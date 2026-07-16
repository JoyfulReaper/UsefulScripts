FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

COPY ["NuGet.config", "./"]
COPY ["local-nuget/", "local-nuget/"]
COPY ["HappyQOTD/HappyQOTD.csproj", "HappyQOTD/"]

WORKDIR /src

COPY ["HappyQOTD/HappyQOTD.csproj", "HappyQOTD/"]
RUN dotnet restore "HappyQOTD/HappyQOTD.csproj"

COPY . .
WORKDIR "/src/HappyQOTD"

RUN dotnet publish \
    "HappyQOTD.csproj" \
    --configuration Release \
    --output /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS final

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY --from=build /app/publish .

ENTRYPOINT ["dotnet", "HappyQOTD.dll"]

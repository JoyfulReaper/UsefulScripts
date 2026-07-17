FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build

WORKDIR /src

COPY . .

RUN dotnet restore \
    HappyDaytime/HappyDaytime.csproj

RUN dotnet publish \
    HappyDaytime/HappyDaytime.csproj \
    --configuration Release \
    --output /app/publish \
    --no-restore \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/runtime:10.0 AS final

WORKDIR /app

COPY --from=build /app/publish .

# Daytime's assigned port is 13, but binding ports below 1024
# usually requires root or extra Linux capabilities.
EXPOSE 1313

ENV HappyDaytime__ListenAddress=0.0.0.0
ENV HappyDaytime__Port=1313
ENV HappyDaytime__MaxConcurrentConnections=100

ENTRYPOINT ["dotnet", "HappyDaytime.dll"]
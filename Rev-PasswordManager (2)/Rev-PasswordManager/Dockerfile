ARG JAVA_VERSION=21

# Stage 1: Build the application
FROM maven:3.9-eclipse-temurin-${JAVA_VERSION}-alpine AS builder

WORKDIR /app

# Copy pom.xml and download dependencies (for layer caching)
COPY pom.xml .
RUN mvn dependency:go-offline -B

# Copy source code and build
COPY src ./src
RUN mvn clean package -DskipTests -B

# Stage 2: Create the runtime image
FROM eclipse-temurin:${JAVA_VERSION}-jre-alpine

# Add labels
LABEL maintainer="password-manager-team"
LABEL description="Password Manager Backend"

# Install wget for health check
RUN apk add --no-cache wget

# Create non-root user for security
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /app

ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"

# Copy the JAR from builder stage
COPY --from=builder /app/target/*.jar app.jar

# Create directories for logs and secure files
RUN mkdir -p logs secure-files && \
  chown -R appuser:appgroup /app

# Switch to non-root user
USER appuser

# Expose port
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/actuator/health/readiness || exit 1

# Run the application
ENTRYPOINT ["sh", "-c", "java $JAVA_OPTS -jar app.jar"]
